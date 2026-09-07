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

    /// Set only for a language that embeds others, and only for a top-level
    /// parser -- a child never gets one, which is what bounds the recursion at
    /// one level regardless of what a future grammar's injections.scm claims.
    private let injectionQuery: Query?
    private let queriesRoot: URL
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
        self.queriesRoot = queriesRoot

        // An injections query that fails to load leaves the document
        // highlighted as plain HTML rather than not at all -- the same
        // fail-soft rule the highlights query follows.
        if allowsInjections, let file = language.injectionQueryFile,
           let data = try? Data(contentsOf: queriesRoot.appendingPathComponent(file)) {
            self.injectionQuery = try? Query(language: tsLanguage, data: data)
        } else {
            self.injectionQuery = nil
        }
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
        let context = SwiftTreeSitter.Predicate.Context(string: source)
        let matches = query.execute(node: root, in: tree).resolve(with: context)
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

        // One list, built from both parsers' tokens together rather than by
        // merging two finished lists: SyntaxTokenList's normalisation has to
        // see every token at once for outermost-wins to mean anything.
        //
        // The parent cannot swallow a child here, and that is a property of the
        // HTML query rather than luck: every node it captures is a leaf except
        // `doctype`, which cannot contain an element. So no HTML capture is an
        // ancestor of the `raw_text` the child fills.
        return SyntaxTokenList(tokens + injectedTokens(in: source, root: root, tree: tree, context: context))
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
    /// begins at `region.range.location` in the document. There is no byte
    /// conversion anywhere -- SwiftTreeSitter parses UTF-16LE, so a capture's
    /// range is already in the same units NSTextStorage uses.
    private func injectedTokens(
        in source: String,
        root: Node,
        tree: MutableTree,
        context: SwiftTreeSitter.Predicate.Context
    ) -> [SyntaxToken] {
        guard let injectionQuery else { return [] }

        let text = source as NSString
        var injected: [SyntaxToken] = []

        let regions = injectionQuery.execute(node: root, in: tree)
            .resolve(with: context)
            .injections()

        for region in regions {
            let range = region.range
            // `<script></script>` and `<script src="...">` both produce an
            // injection, of length zero. Slicing one is harmless and parsing it
            // is pure cost, so they are skipped rather than handled.
            guard range.length > 0, range.location >= 0,
                  NSMaxRange(range) <= text.length,
                  let language = SyntaxLanguage(injectionName: region.name),
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

        return injected
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
