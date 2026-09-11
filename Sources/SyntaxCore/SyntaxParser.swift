import Foundation
import TreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterPython
import TreeSitterTypeScript

/// Turns source text into tokens. One per document.
///
/// Driven through tree-sitter's C API rather than through swift-tree-sitter's
/// `Query`/`QueryCursor`, and that is a performance decision with a measured
/// reason. The Swift wrapper builds a `QueryCapture` for every capture, and each
/// one allocates a name String, a `components(separatedBy:)` array and a
/// metadata Dictionary -- on a dense file that is hundreds of thousands of
/// allocations, and it dominated everything else including the parse. Going
/// straight to `ts_query_cursor_next_match` and reading two byte offsets made
/// tokenising about three times faster, which is what the document size caps in
/// `SyntaxLanguage` are spent on.
///
/// Not `Sendable`: it owns mutable C state. Confine one to the main actor, or
/// to an actor of its own if parsing ever moves off the main thread.
public final class SyntaxParser {

    private let language: SyntaxLanguage
    private let queriesRoot: URL

    // Owned C objects: these three are released in deinit, and `injections`
    // (which owns a second query and cursor) is disposed there too. A
    // top-level parser also retains its last tree between calls (see `tree`);
    // a child's tree is freed at the end of the call that made it.
    //
    // The TSLanguage is deliberately NOT stored and must never be freed:
    // tree_sitter_html() and friends return a pointer to a function-static, so
    // it is borrowed, not owned, and not heap memory at all. The parser and the
    // query each take their own reference to it.
    private let parser: OpaquePointer
    private let query: OpaquePointer
    private let cursor: OpaquePointer

    /// Capture id to token kind, so the hot loop never sees a capture *name*.
    /// This is the single biggest saving: the id is what tree-sitter hands us,
    /// and resolving it through a string was most of the old cost.
    private let kinds: [SyntaxTokenKind?]

    /// Tests a match must pass, by pattern index. Empty for most patterns.
    private let tests: [[CaptureTest]]

    private let injections: InjectionQuery?
    /// Built on first use and kept, because building one compiles a query.
    private var children: [SyntaxLanguage: SyntaxParser] = [:]

    /// Only a document's own parser keeps a tree between calls. A child
    /// parses a substring that moves and changes wholesale with every edit of
    /// the document around it, so there is nothing for it to reuse.
    private let isTopLevel: Bool

    /// The last tree this parser produced, with every edit reported since
    /// applied to it through `ts_tree_edit`, so the next parse can reuse the
    /// subtrees the edits did not touch. nil until the first parse and after
    /// `invalidate()`.
    private var tree: OpaquePointer?
    /// The document length, in bytes, that `tree` currently describes. Kept
    /// in step by `noteEdit` and compared against the real length before
    /// every reuse -- the cheap check that catches an edit nobody reported.
    private var treeByteCount = 0
    /// Whether any edit has been reported since the tree was last built. The
    /// tree is reused ONLY when this is true: a caller that reports its edits
    /// has told us what changed, and a caller that reports nothing may have
    /// changed anything. Without this, `tokens(for:)` would reuse a stale tree
    /// whenever two different texts happened to have the same length -- which
    /// is not a corner case, it is every keystroke that overtypes a selection
    /// of the same size. Found by the differential test, in the test's own
    /// reference parser.
    private var editsSinceParse = false

    /// Returns nil if the grammar or its query cannot be loaded, so a missing or
    /// broken query file degrades to plain text. Never traps: the query is read
    /// from a file inside the app bundle, and a `try!` here would turn a
    /// packaging mistake into a crash on open.
    public convenience init?(language: SyntaxLanguage, queriesRoot: URL) {
        self.init(language: language, queriesRoot: queriesRoot, allowsInjections: true)
    }

    private init?(language: SyntaxLanguage, queriesRoot: URL, allowsInjections: Bool) {
        guard let tsLanguage = Self.grammar(for: language),
              let source = Self.queryText(for: language.queryFiles, root: queriesRoot),
              let query = Self.compile(source, language: tsLanguage),
              let parser = ts_parser_new(),
              let cursor = ts_query_cursor_new()
        else { return nil }

        guard ts_parser_set_language(parser, tsLanguage) else {
            ts_parser_delete(parser)
            ts_query_cursor_delete(cursor)
            ts_query_delete(query)
            return nil
        }

        self.language = language
        self.queriesRoot = queriesRoot
        self.isTopLevel = allowsInjections
        self.parser = parser
        self.query = query
        self.cursor = cursor
        self.kinds = Self.kinds(in: query, for: language)
        self.tests = Self.tests(in: query)

        // An injections query that fails to load leaves the document
        // highlighted as plain HTML rather than not at all -- the same
        // fail-soft rule the highlights query follows. A child parser never
        // gets one, which is what bounds recursion at one level regardless of
        // what a future grammar's injections.scm claims.
        if allowsInjections, let file = language.injectionQueryFile,
           let text = Self.queryText(for: [file], root: queriesRoot),
           let compiled = Self.compile(text, language: tsLanguage) {
            self.injections = InjectionQuery(query: compiled)
        } else {
            self.injections = nil
        }
    }

    deinit {
        if let tree { ts_tree_delete(tree) }
        ts_query_cursor_delete(cursor)
        ts_query_delete(query)
        ts_parser_delete(parser)
        injections?.dispose()
    }

    // MARK: - Edits

    /// One replacement, in UTF-16 units of the document: the text between
    /// `start` and `oldEnd` was replaced by text ending at `newEnd`.
    public struct TextEdit: Equatable, Sendable {
        public let start: Int
        public let oldEnd: Int
        public let newEnd: Int

        public init(start: Int, oldEnd: Int, newEnd: Int) {
            self.start = start
            self.oldEnd = oldEnd
            self.newEnd = newEnd
        }
    }

    /// Reports an edit that has already happened to the text, so that the next
    /// `tokens(for:)` can reuse the parts of the last tree the edit did not
    /// touch. Edits are cumulative: report every one, in order, in the
    /// coordinates of the text as it was just after that edit -- which is
    /// exactly what NSTextStorage's `didProcessEditing` supplies.
    ///
    /// Only the byte offsets are given to tree-sitter; the row/column points
    /// are left at zero. That is safe here and would not be everywhere: every
    /// decision in tree-sitter's node reuse is made on `.bytes` (the points in
    /// parser.c appear only in its log lines), and nothing in this pipeline
    /// ever reads a node's point. `IncrementalParseTests` pins it directly: a
    /// parser given real points and one given zeros produce the same tokens
    /// through the same random edits.
    ///
    /// What the tests require of the result: on text that parses cleanly, the
    /// tokens are identical to a fresh parse of the same text; on text with
    /// syntax errors they may differ, because tree-sitter may recover from an
    /// error differently when reusing a tree than when starting cold -- both
    /// are valid parses of broken text -- and once the error is fixed the two
    /// agree again. Reuse is safe across that because tree-sitter only reuses
    /// a subtree when the parser is in the same state it was originally parsed
    /// in, and never reuses one that has been edited.
    public func noteEdit(_ edit: TextEdit) {
        noteEdit(edit, start: TSPoint(row: 0, column: 0),
                 oldEnd: TSPoint(row: 0, column: 0), newEnd: TSPoint(row: 0, column: 0))
    }

    /// Internal so a test can hand tree-sitter REAL points and check whether
    /// they make any difference to the tokens. They do not; see `noteEdit`.
    func noteEdit(_ edit: TextEdit, start: TSPoint, oldEnd: TSPoint, newEnd: TSPoint) {
        guard isTopLevel, let tree else { return }
        guard edit.start >= 0, edit.start <= edit.oldEnd, edit.start <= edit.newEnd,
              edit.oldEnd * 2 <= treeByteCount
        else {
            // An edit that cannot describe this text means the caller and the
            // tree have already disagreed; better to start over than to guess.
            invalidate()
            return
        }

        var input = TSInputEdit(
            start_byte: UInt32(edit.start * 2),
            old_end_byte: UInt32(edit.oldEnd * 2),
            new_end_byte: UInt32(edit.newEnd * 2),
            start_point: start,
            old_end_point: oldEnd,
            new_end_point: newEnd
        )
        ts_tree_edit(tree, &input)
        treeByteCount += (edit.newEnd - edit.oldEnd) * 2
        editsSinceParse = true
    }

    /// Whether the last retained tree contains syntax errors. Internal, for the
    /// tests that define what "identical to a fresh parse" may be required of:
    /// tree-sitter guarantees it only for text that parses cleanly. On text
    /// with errors an incremental parse may recover differently from a fresh
    /// one -- both are valid parses of broken text -- and the tests check
    /// convergence instead: once the error is fixed, the trees agree again.
    var hasSyntaxErrors: Bool {
        guard let tree else { return false }
        return ts_node_has_error(ts_tree_root_node(tree))
    }

    /// Forgets the retained tree, so the next parse starts from scratch. For
    /// text that arrived some way other than through reported edits.
    public func invalidate() {
        if let tree { ts_tree_delete(tree) }
        tree = nil
        treeByteCount = 0
        editsSinceParse = false
    }

    // MARK: - Tokenising

    /// How long one call to `tokens(for:)` may run before it gives up.
    ///
    /// This is what actually bounds the worst case; the size caps in
    /// `SyntaxLanguage` cannot, because the worst case is set by nesting depth
    /// and unbalanced brackets, which are quadratic in a way no byte count
    /// tracks. Measured in release: a 64 KB file of unclosed `<b>` tags takes
    /// 1.6 s, 128 KB of nested `:is(` takes 11.5 s, 64,000 unclosed parens
    /// take 3.9 s -- each of them per keystroke, on the main thread, and each
    /// of them a shape an ordinary file passes through while being typed.
    ///
    /// 80 ms is chosen against two numbers. A typical file at its size cap
    /// tokenises in 15-20 ms here, so there is 4x of headroom for slower
    /// hardware before a legitimate file is cut. And 80 ms is the upper edge of
    /// what a keystroke can cost before typing feels stuck rather than merely
    /// heavy.
    ///
    /// When the budget runs out the document is left plain. Not partially
    /// coloured: a query stopped halfway has captured the top of the file and
    /// not the bottom, and a half-coloured document reads as broken where a
    /// plain one reads as deliberate.
    public static let defaultBudget: TimeInterval = 0.080

    public func tokens(
        for source: String,
        budget: TimeInterval = SyntaxParser.defaultBudget
    ) -> SyntaxTokenList {
        var deadline = Deadline(after: budget)
        return withUnsafeMutablePointer(to: &deadline) { deadline in
            let result = tokens(for: source, deadline: deadline)
            lastCallWasCut = result == nil
            return result ?? .empty
        }
    }

    /// Whether the most recent `tokens(for:)` gave up because its budget ran
    /// out. An empty result alone cannot say: an empty document is empty too.
    /// The highlighter uses this to space out retries -- see `CutBackoff`.
    public private(set) var lastCallWasCut = false

    /// One absolute deadline shared by every phase of a call -- parse, query,
    /// and each child parser -- so that the phases cannot each spend the whole
    /// budget in turn.
    ///
    /// Handed to tree-sitter as the `payload` of its progress callbacks, which
    /// it invokes every hundred operations. `check()` is the only thing those
    /// callbacks do, and it is one clock read.
    private struct Deadline {
        let uptimeNanoseconds: UInt64
        /// Set the first time a callback observes the deadline passing, and
        /// never cleared: it is what distinguishes "tree-sitter stopped because
        /// we told it to" from "tree-sitter finished".
        var exceeded = false

        init(after budget: TimeInterval) {
            // `UInt64(Double)` TRAPS on infinity, NaN and anything past
            // UInt64.max, and `.infinity` is the obvious spelling for "no
            // budget". So the budget is clamped first: NaN and negatives mean
            // no time at all, and anything past an hour is treated as an hour,
            // which is unlimited for any purpose this has. An hour in
            // nanoseconds is 3.6e12, far inside the type, and &+ keeps the sum
            // with the current uptime from ever wrapping.
            let seconds = budget.isNaN ? 0 : min(max(0, budget), 3600)
            let budgetNanoseconds = UInt64(seconds * 1_000_000_000)
            uptimeNanoseconds = DispatchTime.now().uptimeNanoseconds &+ budgetNanoseconds
        }

        /// Returns true when the work should stop.
        mutating func check() -> Bool {
            if !exceeded, DispatchTime.now().uptimeNanoseconds > uptimeNanoseconds {
                exceeded = true
            }
            return exceeded
        }
    }

    /// Returns nil when the deadline passed before the work was finished, so a
    /// caller can tell "no tokens" from "gave up".
    private func tokens(
        for source: String,
        deadline: UnsafeMutablePointer<Deadline>
    ) -> SyntaxTokenList? {
        // UTF-16 throughout, with no conversion anywhere: tree-sitter is told
        // the buffer is UTF-16LE, so a node's byte offset is exactly twice its
        // UTF-16 offset -- and UTF-16 offsets are what NSRange, NSTextStorage
        // and TextKit 2 all speak.
        let units = Array(source.utf16)
        let text = source as NSString

        return units.withUnsafeBufferPointer { buffer -> SyntaxTokenList? in
            let byteCount = buffer.count * 2

            // The retained tree is reused only if (a) at least one edit has
            // been reported since it was built -- see `editsSinceParse` -- and
            // (b) it describes text of exactly this length. Every reported
            // edit keeps `treeByteCount` in step, so a mismatch means an edit
            // went unreported, and a tree that is out of step would put every
            // token after the discrepancy on the wrong text.
            if tree != nil, !editsSinceParse || treeByteCount != byteCount { invalidate() }

            guard let newTree = Self.parse(buffer, with: parser, oldTree: tree, deadline: deadline)
            else {
                if deadline.pointee.exceeded {
                    // The edited old tree is kept: the edits it carries are
                    // real, and the next keystroke can still reuse it.
                    return nil
                }
                // An empty document has no tree and is not a failure.
                invalidate()
                return .empty
            }

            if isTopLevel {
                if let old = tree { ts_tree_delete(old) }
                tree = newTree
                treeByteCount = byteCount
                editsSinceParse = false
                return tokens(in: newTree, text: text, deadline: deadline)
            } else {
                defer { ts_tree_delete(newTree) }
                return tokens(in: newTree, text: text, deadline: deadline)
            }
        }
    }

    private func tokens(
        in tree: OpaquePointer,
        text: NSString,
        deadline: UnsafeMutablePointer<Deadline>
    ) -> SyntaxTokenList? {
        guard var tokens = captures(in: tree, text: text, deadline: deadline) else {
            return nil
        }
        tokens += injectedTokens(in: tree, text: text, deadline: deadline)
        return SyntaxTokenList(tokens)
    }

    // MARK: - Progress callbacks

    /// `@convention(c)`, so it can capture nothing; the deadline arrives as the
    /// payload tree-sitter hands back.
    private static let parseProgress: @convention(c) (UnsafeMutablePointer<TSParseState>?) -> Bool = {
        state in
        guard let payload = state?.pointee.payload else { return false }
        return payload.assumingMemoryBound(to: Deadline.self).pointee.check()
    }

    private static let queryProgress: @convention(c) (UnsafeMutablePointer<TSQueryCursorState>?) -> Bool = {
        state in
        guard let payload = state?.pointee.payload else { return false }
        return payload.assumingMemoryBound(to: Deadline.self).pointee.check()
    }

    /// nil when the deadline passed mid-walk. A cancelled cursor has returned
    /// the matches it reached and not the rest, so partial output is discarded
    /// rather than shown.
    private func captures(
        in tree: OpaquePointer,
        text: NSString,
        deadline: UnsafeMutablePointer<Deadline>
    ) -> [SyntaxToken]? {
        var tokens: [SyntaxToken] = []
        let root = ts_tree_root_node(tree)
        var options = TSQueryCursorOptions(
            payload: UnsafeMutableRawPointer(deadline),
            progress_callback: Self.queryProgress
        )

        // tree-sitter keeps the POINTER to the options, not a copy, and reads
        // it on every next_match -- so the struct has to outlive the loop, not
        // just the exec call. Hence the closure rather than a plain `&options`.
        return withUnsafePointer(to: &options) { options -> [SyntaxToken]? in
            ts_query_cursor_exec_with_options(cursor, query, root, options)

            var match = TSQueryMatch()
            while ts_query_cursor_next_match(cursor, &match) {
                let captures = UnsafeBufferPointer(
                    start: match.captures,
                    count: Int(match.capture_count)
                )
                guard passes(match: match, captures: captures, text: text, tests: tests)
                else { continue }

                for capture in captures {
                    guard Int(capture.index) < kinds.count,
                          let kind = kinds[Int(capture.index)],
                          let range = Self.range(of: capture.node)
                    else { continue }
                    tokens.append(SyntaxToken(range: range, kind: kind))
                }
            }
            return deadline.pointee.exceeded ? nil : tokens
        }
    }

    // MARK: - Predicates

    /// The predicate forms this evaluates.
    ///
    /// The negated and set-membership forms are here even though no vendored
    /// query uses one yet, because leaving them out is not a loss of fidelity
    /// but an INVERSION: an unrecognised `#not-match?` treated as "passes"
    /// includes exactly the captures the query asked to exclude. Permissive is
    /// the safe default only for predicates that are not negated.
    ///
    /// `#is-not? local` and any genuinely unknown form still pass, which is
    /// what swift-tree-sitter does; answering `is-not? local` would need
    /// locals.scm and a scope resolver.
    private enum CaptureTest {
        /// A test that can never be satisfied. Used when a `#match?` pattern
        /// will not compile: the predicate must still filter, so its captures
        /// are dropped rather than emitted unfiltered.
        case never
        case match(capture: UInt32, regex: NSRegularExpression, negated: Bool)
        case equals(capture: UInt32, values: [NSString], negated: Bool)
        case anyOf(capture: UInt32, values: [NSString], negated: Bool)
    }

    /// Compares a range of the document against a value without copying it out.
    private static func text(
        _ text: NSString,
        _ range: NSRange,
        equals value: NSString
    ) -> Bool {
        range.length == value.length
            && text.compare(value as String, options: [.literal], range: range) == .orderedSame
    }

    /// Evaluated against the document rather than against an extracted
    /// substring. `firstMatch(in:options:range:)` anchors `^` and `$` to the
    /// ends of the search range unless `.withoutAnchoringBounds` is passed, so
    /// the patterns work unchanged -- and nothing is copied. Every one of these
    /// fires on a large fraction of a file (`@constructor` is `^[A-Z]` on every
    /// identifier), so a substring per test would have given back much of what
    /// the C loop just won.
    private func passes(
        match: TSQueryMatch,
        captures: UnsafeBufferPointer<TSQueryCapture>,
        text: NSString,
        tests: [[CaptureTest]]
    ) -> Bool {
        let pattern = Int(match.pattern_index)
        guard pattern < tests.count else { return true }
        let patternTests = tests[pattern]
        guard !patternTests.isEmpty else { return true }

        for test in patternTests {
            switch test {
            case .never:
                return false

            case let .match(index, regex, negated):
                for capture in captures where capture.index == index {
                    guard let range = Self.range(of: capture.node) else { return false }
                    let matched = regex.firstMatch(
                        in: text as String, options: [], range: range
                    ) != nil
                    if matched == negated { return false }
                }

            case let .equals(index, values, negated):
                // Upstream semantics: every listed value must equal the text
                // (or, negated, differ from it).
                for capture in captures where capture.index == index {
                    guard let range = Self.range(of: capture.node) else { return false }
                    let satisfied = values.allSatisfy {
                        Self.text(text, range, equals: $0) != negated
                    }
                    if !satisfied { return false }
                }

            case let .anyOf(index, values, negated):
                for capture in captures where capture.index == index {
                    guard let range = Self.range(of: capture.node) else { return false }
                    let contains = values.contains { Self.text(text, range, equals: $0) }
                    if contains == negated { return false }
                }
            }
        }
        return true
    }

    // MARK: - Injections

    /// A compiled injections query plus what its `#set!` directives say.
    ///
    /// The language of an injection is a static property of the PATTERN -- the
    /// query says `(#set! injection.language "css")` once, not per match -- so
    /// it is resolved when the query is compiled and the match loop only has to
    /// look it up by index.
    private final class InjectionQuery {
        let query: OpaquePointer
        let cursor: OpaquePointer
        /// Language by pattern index, nil where we have no such grammar.
        let languages: [SyntaxLanguage?]
        /// Capture id of `@injection.content`.
        let contentCapture: UInt32?
        /// Capture id of `@injection.language`, for queries that name the
        /// language dynamically rather than through `#set!`.
        let languageCapture: UInt32?
        /// Tests a match must pass, by pattern index. Pattern indices and
        /// capture ids belong to THIS query, which is why this cannot share the
        /// highlights table -- and why an `#eq?`-gated injection was firing
        /// unconditionally before it existed.
        let tests: [[CaptureTest]]

        init(query: OpaquePointer) {
            self.query = query
            self.cursor = ts_query_cursor_new()
            self.contentCapture = SyntaxParser.captureID(named: "injection.content", in: query)
            self.languageCapture = SyntaxParser.captureID(named: "injection.language", in: query)
            self.tests = SyntaxParser.tests(in: query)

            var languages: [SyntaxLanguage?] = []
            for pattern in 0..<Int(ts_query_pattern_count(query)) {
                let settings = SyntaxParser.directives(in: query, pattern: pattern)
                languages.append(
                    settings["injection.language"].flatMap(SyntaxLanguage.init(injectionName:))
                )
            }
            self.languages = languages
        }

        func dispose() {
            ts_query_cursor_delete(cursor)
            ts_query_delete(query)
        }
    }

    /// Tokens for the bodies of embedded languages -- `<script>` and `<style>`
    /// -- expressed in the OUTER document's offsets.
    ///
    /// The region is sliced with `NSString.substring(with:)` rather than
    /// `Range(NSRange, in: String)`, which returns nil when a range boundary
    /// splits a surrogate pair. That cannot actually happen here, since a
    /// `raw_text` boundary always sits on `>` or `<`, but the NSString path is
    /// the one that stays correct if it ever did, and this project has been
    /// bitten by that conversion twice already.
    ///
    /// Shifting by the region's start is the whole of the offset maths: the
    /// child returns UTF-16 offsets into the substring, and the substring
    /// begins at the region's location in the document.
    private func injectedTokens(
        in tree: OpaquePointer,
        text: NSString,
        deadline: UnsafeMutablePointer<Deadline>
    ) -> [SyntaxToken] {
        guard let injections, let contentCapture = injections.contentCapture,
              !deadline.pointee.exceeded
        else { return [] }

        var injected: [SyntaxToken] = []
        let root = ts_tree_root_node(tree)
        // The injections query itself is a handful of matches and is run
        // without a callback; the deadline is enforced inside each child.
        ts_query_cursor_exec(injections.cursor, injections.query, root)

        var match = TSQueryMatch()
        while ts_query_cursor_next_match(injections.cursor, &match) {
            let captures = UnsafeBufferPointer(
                start: match.captures,
                count: Int(match.capture_count)
            )
            // Injection patterns can carry predicates like any others, and the
            // unsafe direction here is the permissive one: a region that should
            // not be injected would be parsed and coloured as another language.
            guard passes(
                match: match,
                captures: captures,
                text: text,
                tests: injections.tests
            ) else { continue }

            guard let language = Self.injectionLanguage(
                for: match,
                captures: captures,
                text: text,
                injections: injections
            ) else { continue }

            for capture in captures where capture.index == contentCapture {
                // `<script></script>` and `<script src="...">` both produce an
                // injection, of length zero. Skipped BEFORE the child parser is
                // resolved -- building one compiles that language's whole
                // query, which is the cost this guard exists to avoid.
                guard let range = Self.range(of: capture.node),
                      range.length > 0,
                      NSMaxRange(range) <= text.length,
                      let child = childParser(for: language)
                else { continue }

                // A child that runs out of time leaves its region plain and
                // the rest of the document coloured. Each parser's own result
                // is all-or-nothing; the composite may be partial only at the
                // granularity of a whole injected region.
                guard let childTokens = child.tokens(
                    for: text.substring(with: range),
                    deadline: deadline
                ) else { continue }

                for token in childTokens.tokens {
                    injected.append(
                        SyntaxToken(
                            range: NSRange(
                                location: token.range.location + range.location,
                                length: token.range.length
                            ),
                            kind: token.kind
                        )
                    )
                }
            }
        }
        return injected
    }

    /// An `@injection.language` capture names the language in the document
    /// text; a `#set!` directive names it in the query. The capture wins where
    /// both exist, which is the order tree-sitter's own tooling uses.
    private static func injectionLanguage(
        for match: TSQueryMatch,
        captures: UnsafeBufferPointer<TSQueryCapture>,
        text: NSString,
        injections: InjectionQuery
    ) -> SyntaxLanguage? {
        if let id = injections.languageCapture {
            for capture in captures where capture.index == id {
                guard let range = Self.range(of: capture.node), range.length > 0,
                      NSMaxRange(range) <= text.length
                else { continue }
                if let language = SyntaxLanguage(injectionName: text.substring(with: range)) {
                    return language
                }
            }
        }
        let pattern = Int(match.pattern_index)
        guard pattern < injections.languages.count else { return nil }
        return injections.languages[pattern]
    }

    private func childParser(for language: SyntaxLanguage) -> SyntaxParser? {
        if let existing = children[language] { return existing }
        guard let child = SyntaxParser(
            language: language,
            queriesRoot: queriesRoot,
            allowsInjections: false
        ) else { return nil }
        children[language] = child
        return child
    }

    // MARK: - Setting up

    private static func grammar(for language: SyntaxLanguage) -> OpaquePointer? {
        switch language {
        case .plain: nil
        case .html: tree_sitter_html()
        case .css: tree_sitter_css()
        case .javascript: tree_sitter_javascript()
        case .typescript: tree_sitter_typescript()
        case .python: tree_sitter_python()
        case .shell: tree_sitter_bash()
        case .java: tree_sitter_java()
        }
    }

    /// Concatenates the language's query files, in order.
    ///
    /// A newline is inserted between them rather than trusting each to end in
    /// one: without it the last pattern of one file and the first of the next
    /// would fuse into a single malformed pattern, and the whole query would
    /// fail to compile at an offset pointing into neither file.
    private static func queryText(for files: [String], root: URL) -> String? {
        guard !files.isEmpty else { return nil }
        var text = ""
        for file in files {
            guard let part = try? String(
                contentsOf: root.appendingPathComponent(file),
                encoding: .utf8
            ) else { return nil }
            text += part
            text += "\n"
        }
        return text
    }

    private static func compile(_ source: String, language: OpaquePointer) -> OpaquePointer? {
        var errorOffset: UInt32 = 0
        var errorType = TSQueryErrorNone
        let utf8 = Array(source.utf8)
        return utf8.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.flatMap { base in
                base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { chars in
                    ts_query_new(
                        language, chars, UInt32(buffer.count), &errorOffset, &errorType
                    )
                }
            }
        }
    }

    /// The buffer tree-sitter reads through. Its `read` callback is
    /// `@convention(c)` and captures nothing, so the pointer and length travel
    /// as the payload.
    private struct InputBuffer {
        let base: UnsafePointer<CChar>
        let byteCount: UInt32
    }

    private static let readInput: @convention(c) (
        UnsafeMutableRawPointer?, UInt32, TSPoint, UnsafeMutablePointer<UInt32>?
    ) -> UnsafePointer<CChar>? = { payload, byteIndex, _, bytesRead in
        guard let payload else {
            bytesRead?.pointee = 0
            return nil
        }
        let buffer = payload.assumingMemoryBound(to: InputBuffer.self).pointee
        guard byteIndex < buffer.byteCount else {
            bytesRead?.pointee = 0
            return buffer.base + Int(buffer.byteCount)
        }
        bytesRead?.pointee = buffer.byteCount - byteIndex
        return buffer.base + Int(byteIndex)
    }

    /// nil for an empty document, and nil when the deadline passed -- the
    /// caller tells them apart through `deadline.exceeded`.
    private static func parse(
        _ units: UnsafeBufferPointer<UInt16>,
        with parser: OpaquePointer,
        oldTree: OpaquePointer?,
        deadline: UnsafeMutablePointer<Deadline>
    ) -> OpaquePointer? {
        // An empty document has no base address, and passing nil would be read
        // as "no input" rather than "no text".
        guard let base = units.baseAddress, !units.isEmpty else { return nil }
        return base.withMemoryRebound(to: CChar.self, capacity: units.count * 2) { chars in
            var buffer = InputBuffer(base: chars, byteCount: UInt32(units.count * 2))
            return withUnsafeMutablePointer(to: &buffer) { buffer in
                let input = TSInput(
                    payload: UnsafeMutableRawPointer(buffer),
                    read: readInput,
                    encoding: TSInputEncodingUTF16LE,
                    decode: nil
                )
                let options = TSParseOptions(
                    payload: UnsafeMutableRawPointer(deadline),
                    progress_callback: parseProgress
                )
                // With an old tree, tree-sitter re-lexes only around the
                // reported edits and reuses every subtree they did not touch.
                // The old tree is neither modified nor consumed; the new one
                // shares its untouched subtrees by reference count.
                let tree = ts_parser_parse_with_options(parser, oldTree, input, options)
                if tree == nil {
                    // MANDATORY after a cancelled parse. tree-sitter's contract
                    // is that the next parse RESUMES where the cancelled one
                    // stopped -- on the same parser, which is this document's
                    // for its whole life. Without this, the keystroke after a
                    // cancellation returns a tree from the previous text, with
                    // node offsets past the end of the current one, and those
                    // become token ranges handed straight to TextKit.
                    ts_parser_reset(parser)
                }
                return tree
            }
        }
    }

    /// Node ranges come back in bytes; UTF-16LE means the conversion is a halving
    /// and nothing else. Guards against a byte offset that is somehow odd rather
    /// than silently rounding it, which would land a token mid-code-unit.
    private static func range(of node: TSNode) -> NSRange? {
        let start = ts_node_start_byte(node)
        let end = ts_node_end_byte(node)
        guard end >= start, start.isMultiple(of: 2), end.isMultiple(of: 2) else { return nil }
        return NSRange(location: Int(start / 2), length: Int((end - start) / 2))
    }

    private static func captureName(_ id: UInt32, in query: OpaquePointer) -> String? {
        var length: UInt32 = 0
        guard let name = ts_query_capture_name_for_id(query, id, &length) else { return nil }
        return String(cString: name)
    }

    private static func captureID(named name: String, in query: OpaquePointer) -> UInt32? {
        for id in 0..<ts_query_capture_count(query) where captureName(id, in: query) == name {
            return id
        }
        return nil
    }

    /// Resolves every capture id to a kind once, at compile time, so that the
    /// match loop is an array subscript rather than a string lookup.
    private static func kinds(
        in query: OpaquePointer,
        for language: SyntaxLanguage
    ) -> [SyntaxTokenKind?] {
        (0..<ts_query_capture_count(query)).map { id in
            captureName(id, in: query).flatMap { SyntaxTokenKind(captureName: $0, in: language) }
        }
    }

    private static func stringValue(_ id: UInt32, in query: OpaquePointer) -> String? {
        var length: UInt32 = 0
        guard let value = ts_query_string_value_for_id(query, id, &length) else { return nil }
        return String(cString: value)
    }

    /// Splits a pattern's predicate steps into one array of arguments per
    /// predicate. tree-sitter delivers them as a flat list terminated by
    /// `.done` steps rather than as a structure.
    private static func predicateGroups(
        in query: OpaquePointer,
        pattern: Int
    ) -> [[TSQueryPredicateStep]] {
        var count: UInt32 = 0
        guard let steps = ts_query_predicates_for_pattern(query, UInt32(pattern), &count),
              count > 0
        else { return [] }

        var groups: [[TSQueryPredicateStep]] = []
        var current: [TSQueryPredicateStep] = []
        for step in UnsafeBufferPointer(start: steps, count: Int(count)) {
            if step.type == TSQueryPredicateStepTypeDone {
                if !current.isEmpty { groups.append(current) }
                current = []
            } else {
                current.append(step)
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private static func tests(in query: OpaquePointer) -> [[CaptureTest]] {
        (0..<Int(ts_query_pattern_count(query))).map { pattern in
            predicateGroups(in: query, pattern: pattern).compactMap { steps -> CaptureTest? in
                guard steps.count >= 2,
                      steps[0].type == TSQueryPredicateStepTypeString,
                      let name = stringValue(steps[0].value_id, in: query),
                      steps[1].type == TSQueryPredicateStepTypeCapture
                else { return nil }

                let capture = steps[1].value_id
                // Every remaining string argument, not just the first:
                // `#any-of? @x "a" "b"` means both, and reading only "a" would
                // quietly narrow the test.
                let values: [NSString] = steps.dropFirst(2).compactMap { step in
                    guard step.type == TSQueryPredicateStepTypeString else { return nil }
                    return stringValue(step.value_id, in: query).map { $0 as NSString }
                }
                let negated = name.hasPrefix("not-")

                switch name {
                case "match?", "not-match?":
                    guard let pattern = values.first else { return nil }
                    // A pattern ICU will not compile makes the test
                    // unsatisfiable rather than absent. `#match?` must really
                    // filter, so an unevaluable one drops its captures instead
                    // of emitting them unfiltered -- the language keeps
                    // highlighting everything else.
                    guard let regex = try? NSRegularExpression(pattern: pattern as String)
                    else { return .never }
                    return .match(capture: capture, regex: regex, negated: negated)

                case "eq?", "not-eq?":
                    // The capture-to-capture form `#eq? @a @b` has no string
                    // arguments; it is not supported and passes.
                    guard !values.isEmpty else { return nil }
                    return .equals(capture: capture, values: values, negated: negated)

                case "any-of?", "not-any-of?":
                    guard !values.isEmpty else { return nil }
                    return .anyOf(capture: capture, values: values, negated: negated)

                default:
                    // Passes. `#is-not? local` lands here, and answering it
                    // would need locals.scm and a scope resolver.
                    return nil
                }
            }
        }
    }

    /// `#set!` directives for a pattern, as key/value pairs.
    private static func directives(
        in query: OpaquePointer,
        pattern: Int
    ) -> [String: String] {
        var settings: [String: String] = [:]
        for steps in predicateGroups(in: query, pattern: pattern) {
            guard steps.count >= 3,
                  steps.allSatisfy({ $0.type == TSQueryPredicateStepTypeString }),
                  stringValue(steps[0].value_id, in: query) == "set!",
                  let key = stringValue(steps[1].value_id, in: query),
                  let value = stringValue(steps[2].value_id, in: query)
            else { continue }
            settings[key] = value
        }
        return settings
    }
}
