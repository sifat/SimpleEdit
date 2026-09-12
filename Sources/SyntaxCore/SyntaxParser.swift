import Foundation
import TreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterPHP
import TreeSitterPython
import TreeSitterSql
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

    /// How deep injections may nest. 0 is the document's own parser, and each
    /// level of embedding is one more. Two, because PHP needs two: a `.php`
    /// file is PHP, the text between its `?>` and `<?php` is one HTML
    /// document, and that HTML has its own `<script>` and `<style>`. Nothing
    /// vendored needs three, and the constant is what stops a grammar whose
    /// injections.scm names itself from recursing for ever.
    static let maximumInjectionDepth = 2

    /// 0 for a document's own parser, one more for each level of injection.
    private let depth: Int

    /// Only a document's own parser keeps a tree between calls. A child
    /// parses a region that moves and changes wholesale with every edit of the
    /// document around it, so there is nothing for it to reuse.
    private var isTopLevel: Bool { depth == 0 }

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
        self.init(language: language, queriesRoot: queriesRoot, depth: 0)
    }

    private init?(language: SyntaxLanguage, queriesRoot: URL, depth: Int) {
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
        self.depth = depth
        self.parser = parser
        self.query = query
        self.cursor = cursor
        self.kinds = Self.kinds(in: query, for: language)
        self.tests = Self.tests(in: query)

        // An injections query that fails to load leaves the document
        // highlighted as plain HTML rather than not at all -- the same
        // fail-soft rule the highlights query follows. The depth test is what
        // bounds recursion regardless of what a grammar's injections.scm
        // claims: at the deepest level no injections query is loaded at all,
        // so a child cannot inject further.
        if depth < Self.maximumInjectionDepth, let file = language.injectionQueryFile,
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
              edit.oldEnd * 2 <= treeByteCount,
              // The only bound `newEnd` has is tree-sitter's 32-bit offsets;
              // past it, the UInt32 conversion below would trap rather than
              // start over, which is the wrong answer to a nonsense edit.
              edit.newEnd <= Int(UInt32.max) / 2
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
        lastCallWasCut = false
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

            // A child parser is shared between regions parsed as a substring
            // and regions parsed through included ranges -- see `run` -- and
            // included ranges live on the PARSER, not the call. A substring is
            // the whole of its own input, so they are cleared here.
            if !isTopLevel { ts_parser_set_included_ranges(parser, nil, 0) }

            guard let newTree = Self.parse(buffer, with: parser, oldTree: tree, deadline: deadline)
            else {
                if deadline.pointee.exceeded {
                    // The edited old tree is kept: the edits it carries are
                    // real, and the next keystroke can still reuse it -- once
                    // it has reported its edit. Reuse is re-earned, not
                    // carried over: the guard above trusts this flag to mean
                    // "every change since the tree was built was reported",
                    // and a cut is a call, so a caller that reports nothing
                    // before the next one may have changed anything.
                    editsSinceParse = false
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
                return tokens(in: newTree, document: buffer, text: text, ranges: nil, deadline: deadline)
            } else {
                defer { ts_tree_delete(newTree) }
                return tokens(in: newTree, document: buffer, text: text, ranges: nil, deadline: deadline)
            }
        }
    }

    /// A child's other entry point: the WHOLE document's buffer, with the
    /// parser confined to `ranges` through tree-sitter's included ranges.
    ///
    /// This is what a COMBINED injection needs. The HTML of a PHP template is
    /// one document that PHP blocks cut holes in -- an element can open before
    /// a `<?php` and close after the matching `?>` -- so parsing each fragment
    /// on its own reports errors that are not in the file. Included ranges let
    /// tree-sitter lex the fragments as one continuous stream, skipping the
    /// holes. Measured over 381 WordPress templates: 521 ERROR nodes when the
    /// fragments are parsed separately, 126 when they are parsed as one.
    ///
    /// Offsets need no shifting afterwards, because the child read the
    /// document's own buffer: its node offsets ARE document offsets.
    ///
    /// `ranges` is sorted, disjoint and non-empty, in UTF-16 units.
    private func childTokens(
        document: UnsafeBufferPointer<UInt16>,
        text: NSString,
        ranges: [NSRange],
        deadline: UnsafeMutablePointer<Deadline>
    ) -> SyntaxTokenList? {
        var tsRanges = Self.tsRanges(ranges, in: document)
        guard ts_parser_set_included_ranges(parser, &tsRanges, UInt32(tsRanges.count))
        else { return nil }
        guard let newTree = Self.parse(document, with: parser, oldTree: nil, deadline: deadline)
        else { return nil }
        defer { ts_tree_delete(newTree) }
        return tokens(in: newTree, document: document, text: text, ranges: ranges, deadline: deadline)
    }

    private func tokens(
        in tree: OpaquePointer,
        document: UnsafeBufferPointer<UInt16>,
        text: NSString,
        ranges: [NSRange]?,
        deadline: UnsafeMutablePointer<Deadline>
    ) -> SyntaxTokenList? {
        guard var tokens = captures(in: tree, text: text, deadline: deadline) else {
            return nil
        }
        // A node of the injected language can span one of the holes -- an
        // attribute value with a `<?php echo $x; ?>` in the middle of it is one
        // HTML node -- and outermost-wins would let that single token swallow
        // every PHP token inside the hole. So a child's tokens are cut back to
        // its own ranges. With one range this cannot fire: tree-sitter never
        // reports a node outside the ranges it was given.
        if let ranges { tokens = Self.clip(tokens, to: ranges) }
        tokens += injectedTokens(
            in: tree, document: document, text: text, parentRanges: ranges, deadline: deadline
        )
        // A cut ANYWHERE is a cut of the whole call. A child that ran out of
        // time has returned nothing for its region, and nothing here can tell
        // that from a region with nothing to colour -- so without this the
        // outer tokens were reported as a success, `lastCallWasCut` stayed
        // false, the backoff reset, and a hostile `<script>` burned the whole
        // budget on every keystroke: the exact case CutBackoff exists for.
        // Keeping the outer tokens would be no better. During the keystrokes
        // the backoff skips they would be painted, stale, over text that has
        // moved; plain is what the README promises for a cut document.
        if deadline.pointee.exceeded { return nil }
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
        /// `(#set! injection.combined)`, by pattern index: every match of the
        /// pattern belongs to ONE injected document rather than being a region
        /// of its own.
        let combined: [Bool]

        init(query: OpaquePointer) {
            self.query = query
            self.cursor = ts_query_cursor_new()
            self.contentCapture = SyntaxParser.captureID(named: "injection.content", in: query)
            self.languageCapture = SyntaxParser.captureID(named: "injection.language", in: query)
            self.tests = SyntaxParser.tests(in: query)

            var languages: [SyntaxLanguage?] = []
            var combined: [Bool] = []
            for pattern in 0..<Int(ts_query_pattern_count(query)) {
                let settings = SyntaxParser.directives(in: query, pattern: pattern)
                languages.append(
                    settings["injection.language"].flatMap(SyntaxLanguage.init(injectionName:))
                )
                combined.append(settings["injection.combined"] != nil)
            }
            self.languages = languages
            self.combined = combined
        }

        func dispose() {
            ts_query_cursor_delete(cursor)
            ts_query_delete(query)
        }
    }

    /// One combined injection: every content node a pattern captured for one
    /// language. Ordered so the work is done in a fixed order.
    private struct CombinedKey: Hashable, Comparable {
        let pattern: Int
        let language: SyntaxLanguage

        static func < (lhs: CombinedKey, rhs: CombinedKey) -> Bool {
            (lhs.pattern, lhs.language.rawValue) < (rhs.pattern, rhs.language.rawValue)
        }
    }

    /// Tokens for the bodies of embedded languages -- `<script>` and `<style>`
    /// inside HTML, and the HTML around the PHP of a template -- expressed in
    /// the OUTER document's offsets.
    ///
    /// Two shapes of injection, and the query says which:
    ///
    /// - ordinary: every match is a region of its own, parsed on its own.
    ///   HTML's `<script>` and `<style>` are these.
    /// - combined (`(#set! injection.combined)`): every match of the pattern
    ///   belongs to ONE document, parsed once over all of their ranges
    ///   together. PHP's `(text)` is this, and it has to be -- the HTML of a
    ///   template is a single document with PHP-shaped holes cut in it, not a
    ///   series of unrelated fragments.
    ///
    /// Either way a region is cut to this parser's own ranges, so a `<script>`
    /// inside PHP-split HTML excludes the PHP within it.
    private func injectedTokens(
        in tree: OpaquePointer,
        document: UnsafeBufferPointer<UInt16>,
        text: NSString,
        parentRanges: [NSRange]?,
        deadline: UnsafeMutablePointer<Deadline>
    ) -> [SyntaxToken] {
        guard let injections, let contentCapture = injections.contentCapture,
              !deadline.pointee.exceeded
        else { return [] }

        var injected: [SyntaxToken] = []
        /// Content nodes of each combined injection, gathered until the walk
        /// ends because a combined injection is only whole once every match is
        /// in. Keyed by pattern AND language: a pattern that names its language
        /// through an `@injection.language` capture can name a different one
        /// per match, and keying by pattern alone would parse every match as
        /// whatever the first one said.
        var combined: [CombinedKey: [TSNode]] = [:]
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

            let pattern = Int(match.pattern_index)
            let isCombined = pattern < injections.combined.count && injections.combined[pattern]

            for capture in captures where capture.index == contentCapture {
                // `<script></script>` and `<script src="...">` both produce an
                // injection, of length zero. Skipped BEFORE the child parser is
                // resolved -- building one compiles that language's whole
                // query, which is the cost this guard exists to avoid.
                guard let range = Self.range(of: capture.node),
                      range.length > 0,
                      NSMaxRange(range) <= text.length
                else { continue }

                if isCombined {
                    combined[CombinedKey(pattern: pattern, language: language), default: []]
                        .append(capture.node)
                    continue
                }

                let ranges = Self.includedRanges(of: [capture.node], within: parentRanges)
                guard !ranges.isEmpty, !deadline.pointee.exceeded,
                      let child = childParser(for: language)
                else { continue }

                // A child that runs out of time leaves the deadline marked
                // exceeded, and `tokens(in:)` then discards the whole call --
                // see the comment there for why a partial result is worse
                // than none.
                injected += Self.run(
                    child, ranges: ranges, document: document, text: text, deadline: deadline
                )
            }
        }

        // Sorted, so the order of the work does not depend on the order the
        // query walk happened to report matches in.
        for key in combined.keys.sorted() {
            guard let nodes = combined[key], !deadline.pointee.exceeded else { continue }
            let ranges = Self.includedRanges(of: nodes, within: parentRanges)
            guard !ranges.isEmpty, let child = childParser(for: key.language) else { continue }
            injected += Self.run(
                child, ranges: ranges, document: document, text: text, deadline: deadline
            )
        }
        return injected
    }

    /// One region, one child.
    ///
    /// A region that is a single contiguous range is parsed as a SUBSTRING and
    /// shifted -- the path `<script>` and `<style>` have always taken. It is
    /// kept rather than folded into the included-ranges path because the two
    /// are not equivalent on broken text: tree-sitter prices its error recovery
    /// partly by byte position, so an unterminated script can recover
    /// differently when read as part of a larger buffer. Only a region the host
    /// language splits into several ranges needs included ranges.
    private static func run(
        _ child: SyntaxParser,
        ranges: [NSRange],
        document: UnsafeBufferPointer<UInt16>,
        text: NSString,
        deadline: UnsafeMutablePointer<Deadline>
    ) -> [SyntaxToken] {
        if ranges.count == 1 {
            let range = ranges[0]
            guard let childTokens = child.tokens(
                for: text.substring(with: range),
                deadline: deadline
            ) else { return [] }
            return childTokens.tokens.map {
                SyntaxToken(
                    range: NSRange(
                        location: $0.range.location + range.location,
                        length: $0.range.length
                    ),
                    kind: $0.kind
                )
            }
        }
        return child.childTokens(
            document: document, text: text, ranges: ranges, deadline: deadline
        )?.tokens ?? []
    }

    /// UTF-16 ranges as tree-sitter's byte ranges, with REAL row and column
    /// points.
    ///
    /// Points are zero everywhere else here -- see `noteEdit` -- and that is
    /// safe because nothing in this pipeline reads a node's point. Included
    /// ranges are the exception, and not because of what we read: tree-sitter
    /// seeds the lexer's position from the range itself, so zero points tell it
    /// every fragment begins at row 0 column 0, and a grammar that asks where
    /// it is on the line is then answered wrongly. Measured on a fuzz walk over
    /// WordPress templates: zero points moved 108 tokens and 12 node structures
    /// that real points left alone. The scan costs 1.27 ms across 3.1 MB.
    ///
    /// Column is in BYTES, which is how tree-sitter counts it, so a UTF-16
    /// offset is doubled. Checked against the host grammar's own node points
    /// over three corpora: no disagreements.
    private static func tsRanges(
        _ ranges: [NSRange],
        in document: UnsafeBufferPointer<UInt16>
    ) -> [TSRange] {
        var out: [TSRange] = []
        out.reserveCapacity(ranges.count)
        // One forward scan serves the whole list, because the ranges are
        // sorted: the line counter never has to go back.
        var row: UInt32 = 0
        var lineStart = 0
        var scanned = 0
        func point(_ offset: Int) -> TSPoint {
            while scanned < offset {
                if document[scanned] == 0x000A {
                    row += 1
                    lineStart = scanned + 1
                }
                scanned += 1
            }
            return TSPoint(row: row, column: UInt32((offset - lineStart) * 2))
        }
        for range in ranges {
            let start = point(range.location)
            let end = point(NSMaxRange(range))
            out.append(TSRange(
                start_point: start,
                end_point: end,
                start_byte: UInt32(range.location * 2),
                end_byte: UInt32(NSMaxRange(range) * 2)
            ))
        }
        return out
    }

    /// The ranges an injection covers: its content nodes, merged, and cut to
    /// the host parser's own ranges (nil meaning the whole document). Sorted
    /// and disjoint, which is what `ts_parser_set_included_ranges` requires.
    ///
    /// Upstream's tree-sitter-highlight also subtracts each content node's
    /// CHILDREN unless the pattern sets `injection.include-children`. Neither
    /// vendored query captures a node that has any -- HTML's `raw_text` and
    /// PHP's `text` are both leaves -- so that step would do nothing here, and
    /// it is left out rather than written blind against no test.
    private static func includedRanges(
        of nodes: [TSNode],
        within parent: [NSRange]?
    ) -> [NSRange] {
        var pieces: [NSRange] = []
        pieces.reserveCapacity(nodes.count)
        for node in nodes {
            guard let range = range(of: node), range.length > 0 else { continue }
            pieces.append(range)
        }
        pieces.sort { $0.location < $1.location }

        var merged: [NSRange] = []
        merged.reserveCapacity(pieces.count)
        for piece in pieces {
            if let last = merged.last, piece.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, piece)
            } else {
                merged.append(piece)
            }
        }
        guard let parent else { return merged }

        // Both lists are sorted, so this is one walk rather than a search per
        // piece.
        var result: [NSRange] = []
        var index = 0
        for piece in merged {
            while index < parent.count, NSMaxRange(parent[index]) <= piece.location {
                index += 1
            }
            var scan = index
            while scan < parent.count, parent[scan].location < NSMaxRange(piece) {
                let lower = max(piece.location, parent[scan].location)
                let upper = min(NSMaxRange(piece), NSMaxRange(parent[scan]))
                if upper > lower {
                    result.append(NSRange(location: lower, length: upper - lower))
                }
                scan += 1
            }
        }
        return result
    }

    /// Cuts tokens back to `ranges` (sorted, disjoint). A token wholly inside
    /// one range passes through untouched; one that spans a hole is split, so
    /// that the host language's tokens inside that hole are not swallowed by
    /// the outermost-wins merge.
    private static func clip(_ tokens: [SyntaxToken], to ranges: [NSRange]) -> [SyntaxToken] {
        guard ranges.count > 1 else {
            guard let only = ranges.first else { return [] }
            return tokens.compactMap { token in
                let lower = max(token.range.location, only.location)
                let upper = min(NSMaxRange(token.range), NSMaxRange(only))
                guard upper > lower else { return nil }
                if lower == token.range.location, upper == NSMaxRange(token.range) { return token }
                return SyntaxToken(
                    range: NSRange(location: lower, length: upper - lower),
                    kind: token.kind
                )
            }
        }
        var out: [SyntaxToken] = []
        out.reserveCapacity(tokens.count)
        for token in tokens {
            let start = token.range.location
            let end = NSMaxRange(token.range)
            // The overwhelmingly common case is a token inside one range, so
            // it is found by binary search and nothing is allocated.
            var low = 0
            var high = ranges.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(ranges[middle]) <= start { low = middle + 1 } else { high = middle }
            }
            if low < ranges.count, ranges[low].location <= start, end <= NSMaxRange(ranges[low]) {
                out.append(token)
                continue
            }
            var index = low
            while index < ranges.count, ranges[index].location < end {
                let lower = max(start, ranges[index].location)
                let upper = min(end, NSMaxRange(ranges[index]))
                if upper > lower {
                    out.append(SyntaxToken(
                        range: NSRange(location: lower, length: upper - lower),
                        kind: token.kind
                    ))
                }
                index += 1
            }
        }
        return out
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
            depth: depth + 1
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
        case .php: tree_sitter_php()
        case .sql: tree_sitter_sql()
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
                    guard let regex = try? NSRegularExpression(
                        pattern: Self.icuPattern(from: pattern as String)
                    )
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

    /// A `#match?` pattern in ICU's dialect, translating Lua's character
    /// classes on the way if it has any.
    ///
    /// `#match?` has no single dialect. tree-sitter's own tooling uses Rust
    /// regex, this app uses ICU through NSRegularExpression, and **Neovim uses
    /// Lua patterns**, where a character class is written `%d` rather than
    /// `\d`. Every query vendored here came from a grammar that publishes for
    /// tree-sitter's tooling -- except SQL's, which is written for Neovim, and
    /// whose two predicates are `^[-+]?%d+$` and `^[-+]?%d*%.%d*$`.
    ///
    /// Left untranslated those are valid ICU patterns that mean something else
    /// entirely: `%d` matches a literal `%` followed by `d`, so neither ever
    /// matches a number. That is not a missing colour but a WRONG one --
    /// `(literal)` is captured as `@string` too, so every number in a SQL file
    /// would be dropped from `@number` and left red as a string.
    ///
    /// The translation is deliberately narrow. It does nothing at all unless
    /// the pattern contains a `%`, and no `#match?` pattern in any other
    /// vendored query does (the `"%"` in JavaScript's and Python's queries is
    /// the modulo OPERATOR, a pattern literal, which never reaches here). Lua's
    /// `%` before a non-alphanumeric is its escape, which becomes ICU's
    /// backslash; before a class letter it becomes the class; and `%%` is a
    /// literal per cent.
    private static func icuPattern(from pattern: String) -> String {
        guard pattern.contains("%") else { return pattern }
        var out = ""
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "%", index + 1 < characters.count else {
                out.append(character)
                index += 1
                continue
            }
            let next = characters[index + 1]
            switch next {
            case "d": out += "[0-9]"
            case "D": out += "[^0-9]"
            case "a": out += "[A-Za-z]"
            case "A": out += "[^A-Za-z]"
            case "l": out += "[a-z]"
            case "u": out += "[A-Z]"
            case "w": out += "[A-Za-z0-9]"
            case "W": out += "[^A-Za-z0-9]"
            case "x": out += "[0-9A-Fa-f]"
            case "s": out += "[ \\t\\n\\r\\u{0B}\\u{0C}]"
            case "S": out += "[^ \\t\\n\\r\\u{0B}\\u{0C}]"
            case "p": out += "[\\p{P}\\p{S}]"
            case "%": out += "%"
            default:
                // Lua escapes a magic character with `%`; ICU with a
                // backslash. A letter or digit we do not know is left as it
                // was, so an unrecognised class cannot silently become
                // something else.
                if next.isLetter || next.isNumber {
                    out.append(character)
                    out.append(next)
                } else {
                    out.append("\\")
                    out.append(next)
                }
            }
            index += 2
        }
        return out
    }

    /// `#set!` directives for a pattern, as key/value pairs.
    ///
    /// A directive may carry no value at all -- `(#set! injection.combined)` is
    /// a flag, and PHP's injections query uses exactly that form -- so a
    /// two-step group is read as a key with an empty value. Callers testing a
    /// flag ask whether the key is present; callers reading a name, such as
    /// `injection.language`, get "" and find no language of that name.
    private static func directives(
        in query: OpaquePointer,
        pattern: Int
    ) -> [String: String] {
        var settings: [String: String] = [:]
        for steps in predicateGroups(in: query, pattern: pattern) {
            guard steps.count >= 2,
                  steps.allSatisfy({ $0.type == TSQueryPredicateStepTypeString }),
                  stringValue(steps[0].value_id, in: query) == "set!",
                  let key = stringValue(steps[1].value_id, in: query)
            else { continue }
            settings[key] = steps.count >= 3
                ? (stringValue(steps[2].value_id, in: query) ?? "")
                : ""
        }
        return settings
    }
}
