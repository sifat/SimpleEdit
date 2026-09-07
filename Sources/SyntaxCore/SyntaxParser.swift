import Foundation
import SwiftTreeSitter
import TreeSitterCSS
import TreeSitterHTML
import TreeSitterJavaScript
import TreeSitterTypeScript

/// Turns source text into tokens. One per document.
///
/// Not `Sendable`: `Parser` and `QueryCursor` are reference types with mutable
/// C state behind them. Confine one of these to the main actor, or to an actor
/// of its own if parsing ever moves off the main thread.
public final class SyntaxParser {

    private let parser: Parser
    private let query: Query
    /// Kept because capture names are interpreted per language: `@variable`
    /// means a custom property in CSS and any identifier at all in JavaScript.
    private let language: SyntaxLanguage

    /// Returns nil if the grammar or its query cannot be loaded, so a missing or
    /// broken query file degrades to plain text. Never traps: the query is read
    /// from a file inside the app bundle, and a `try!` here would turn a
    /// packaging mistake into a crash on open.
    public init?(language: SyntaxLanguage, queriesRoot: URL) {
        guard let grammar = Self.grammar(for: language) else { return nil }
        let tsLanguage = Language(grammar)
        guard let query = Self.query(for: language, tsLanguage: tsLanguage, queriesRoot: queriesRoot)
        else { return nil }

        let parser = Parser()
        do {
            try parser.setLanguage(tsLanguage)
        } catch {
            return nil
        }

        self.parser = parser
        self.query = query
        self.language = language
    }

    public func tokens(for source: String) -> SyntaxTokenList {
        // The whole-string overload, deliberately. parse(tree:string:) reads
        // through a chunked reader that slices on a 1024-UTF-16-unit boundary
        // with Range(_:in:), which returns nil when the boundary splits a
        // surrogate pair -- the read block then reports nil, tree-sitter takes
        // it for EOF, and the document is silently parsed only as far as the
        // first emoji. This path hands the whole buffer over in one call.
        guard let tree = parser.parse(source), let root = tree.rootNode else {
            return .empty
        }

        // Predicates are resolved, not ignored. tree-sitter parses `#match?`
        // and friends but deliberately does not evaluate them -- it hands them
        // to the caller. Skipping that step is not a small loss of fidelity, it
        // inverts the predicate: the CSS query says
        //
        //     ((plain_value) @variable (#match? @variable "^--"))
        //
        // and an unevaluated predicate means EVERY plain value is captured as a
        // variable, so `block` in `display: block` would be coloured. The HTML
        // query carries no predicates, so this costs it nothing.
        //
        // Context(string:) wraps a caching text provider, so a value read for
        // one predicate is not sliced out of the source again for the next.
        let matches = query.execute(node: root, in: tree)
            .resolve(with: Predicate.Context(string: source))
        let tokens = matches
            .flatMap(\.captures)
            .compactMap { capture -> SyntaxToken? in
                guard let name = capture.name,
                      let kind = SyntaxTokenKind(captureName: name, in: self.language)
                else { return nil }
                // capture.range is an NSRange in UTF-16 code units, the same
                // unit NSTextStorage uses. No conversion, by design.
                return SyntaxToken(range: capture.range, kind: kind)
            }

        return SyntaxTokenList(tokens)
    }

    private static func grammar(for language: SyntaxLanguage) -> OpaquePointer? {
        switch language {
        case .plain: nil
        case .html: tree_sitter_html()
        case .css: tree_sitter_css()
        case .javascript: tree_sitter_javascript()
        case .typescript: tree_sitter_typescript()
        }
    }

    /// Builds the query from `language.queryFiles`, concatenated in order.
    ///
    /// Deliberately not `LanguageConfiguration(_:name:queriesURL:)`, which
    /// resolves exactly one hardcoded `highlights.scm` per directory. That is
    /// one file too few for TypeScript, whose own query is a fragment upstream
    /// composes with JavaScript's -- and the failure mode of loading the
    /// fragment alone is silent, not loud.
    ///
    /// A newline is inserted between files rather than trusting each to end in
    /// one: without it the last pattern of one file and the first of the next
    /// would fuse into a single malformed pattern, and the whole query would
    /// fail to compile with an offset pointing at neither file.
    private static func query(
        for language: SyntaxLanguage,
        tsLanguage: Language,
        queriesRoot: URL
    ) -> Query? {
        let files = language.queryFiles
        guard !files.isEmpty else { return nil }

        var data = Data()
        for file in files {
            guard let part = try? Data(contentsOf: queriesRoot.appendingPathComponent(file))
            else { return nil }
            data.append(part)
            data.append(0x0A)
        }
        return try? Query(language: tsLanguage, data: data)
    }
}
