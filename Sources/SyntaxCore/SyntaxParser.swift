import Foundation
import TreeSitter
import TreeSitterCSS
import TreeSitterHTML
import TreeSitterJavaScript
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
    // (which owns a second query and cursor) is disposed there too. The tree
    // from each parse is freed at the end of the call that made it.
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
        ts_query_cursor_delete(cursor)
        ts_query_delete(query)
        ts_parser_delete(parser)
        injections?.dispose()
    }

    // MARK: - Tokenising

    public func tokens(for source: String) -> SyntaxTokenList {
        // UTF-16 throughout, with no conversion anywhere: tree-sitter is told
        // the buffer is UTF-16LE, so a node's byte offset is exactly twice its
        // UTF-16 offset -- and UTF-16 offsets are what NSRange, NSTextStorage
        // and TextKit 2 all speak.
        let units = Array(source.utf16)
        let text = source as NSString

        return units.withUnsafeBufferPointer { buffer -> SyntaxTokenList in
            guard let tree = Self.parse(buffer, with: parser) else { return .empty }
            defer { ts_tree_delete(tree) }

            var tokens = captures(in: tree, text: text)
            tokens += injectedTokens(in: tree, source: source, text: text)
            return SyntaxTokenList(tokens)
        }
    }

    private func captures(in tree: OpaquePointer, text: NSString) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        let root = ts_tree_root_node(tree)
        ts_query_cursor_exec(cursor, query, root)

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
        return tokens
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
        source: String,
        text: NSString
    ) -> [SyntaxToken] {
        guard let injections, let contentCapture = injections.contentCapture else { return [] }

        var injected: [SyntaxToken] = []
        let root = ts_tree_root_node(tree)
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

                for token in child.tokens(for: text.substring(with: range)).tokens {
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

    private static func parse(
        _ units: UnsafeBufferPointer<UInt16>,
        with parser: OpaquePointer
    ) -> OpaquePointer? {
        // An empty document has no base address, and passing nil would be read
        // as "no input" rather than "no text".
        guard let base = units.baseAddress, !units.isEmpty else { return nil }
        return base.withMemoryRebound(to: CChar.self, capacity: units.count * 2) { chars in
            ts_parser_parse_string_encoding(
                parser, nil, chars, UInt32(units.count * 2), TSInputEncodingUTF16LE
            )
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
