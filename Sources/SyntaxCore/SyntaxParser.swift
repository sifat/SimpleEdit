import Foundation
import SwiftTreeSitter
import TreeSitterCSS
import TreeSitterHTML

/// Turns source text into tokens. One per document.
///
/// Not `Sendable`: `Parser` and `QueryCursor` are reference types with mutable
/// C state behind them. Confine one of these to the main actor, or to an actor
/// of its own if parsing ever moves off the main thread.
public final class SyntaxParser {

    private let parser: Parser
    private let query: Query

    /// Returns nil if the grammar or its query cannot be loaded, so a missing or
    /// broken query file degrades to plain text. Never traps: the query is read
    /// from a file inside the app bundle, and a `try!` here would turn a
    /// packaging mistake into a crash on open.
    public init?(language: SyntaxLanguage, queriesRoot: URL) {
        guard let configuration = Self.configuration(for: language, queriesRoot: queriesRoot),
              let highlights = configuration.queries[.highlights]
        else { return nil }

        let parser = Parser()
        do {
            try parser.setLanguage(configuration.language)
        } catch {
            return nil
        }

        self.parser = parser
        self.query = highlights
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
                      let kind = SyntaxTokenKind(captureName: name)
                else { return nil }
                // capture.range is an NSRange in UTF-16 code units, the same
                // unit NSTextStorage uses. No conversion, by design.
                return SyntaxToken(range: capture.range, kind: kind)
            }

        return SyntaxTokenList(tokens)
    }

    private static func configuration(
        for language: SyntaxLanguage,
        queriesRoot: URL
    ) -> LanguageConfiguration? {
        guard let directory = language.queryDirectoryName else { return nil }
        let tsLanguage: OpaquePointer
        switch language {
        case .plain: return nil
        case .html: tsLanguage = tree_sitter_html()
        case .css: tsLanguage = tree_sitter_css()
        }

        return try? LanguageConfiguration(
            Language(tsLanguage),
            name: directory,
            queriesURL: queriesRoot.appendingPathComponent(directory, isDirectory: true)
        )
    }
}
