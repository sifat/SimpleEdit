import Foundation
import Testing
@testable import SyntaxCore

/// Predicate evaluation, tested against synthetic queries.
///
/// None of the vendored queries uses a negated or set-membership predicate
/// today, which is exactly why these exist: the failure mode for an
/// unimplemented negated predicate is not "does less", it is **inverted** --
/// treating `#not-match?` as passing includes precisely the captures the query
/// asked to exclude. A grammar bump that starts using one would otherwise turn
/// colour on where it should turn it off, silently.
@Suite("Predicates")
struct PredicateTests {

    /// Writes a queries tree containing one language's files and returns its root.
    private func root(_ files: [String: String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("syntax-predicates-\(UUID().uuidString)", isDirectory: true)
        for (path, text) in files {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return base
    }

    private func highlight(
        _ source: String,
        javascriptQuery query: String
    ) throws -> [(String, SyntaxTokenKind)] {
        let queries = try root(["javascript/highlights.scm": query])
        defer { try? FileManager.default.removeItem(at: queries) }
        let parser = try #require(SyntaxParser(language: .javascript, queriesRoot: queries))
        let text = source as NSString
        return parser.tokens(for: source).tokens.map {
            (text.substring(with: $0.range), $0.kind)
        }
    }

    @Test("#match? filters to what it matches")
    func match() throws {
        let found = try highlight(
            "alpha; Beta; gamma;",
            javascriptQuery: #"((identifier) @keyword (#match? @keyword "^[A-Z]"))"#
        )
        #expect(found.map(\.0) == ["Beta"])
    }

    /// The inversion this suite exists for.
    @Test("#not-match? excludes what it matches, rather than passing everything")
    func notMatch() throws {
        let found = try highlight(
            "alpha; Beta; gamma;",
            javascriptQuery: #"((identifier) @keyword (#not-match? @keyword "^[A-Z]"))"#
        )
        #expect(found.map(\.0) == ["alpha", "gamma"])
    }

    @Test("#eq? and #not-eq? compare the captured text")
    func equality() throws {
        let source = "alpha; beta;"
        #expect(
            try highlight(source, javascriptQuery: #"((identifier) @keyword (#eq? @keyword "beta"))"#)
                .map(\.0) == ["beta"]
        )
        #expect(
            try highlight(source, javascriptQuery: #"((identifier) @keyword (#not-eq? @keyword "beta"))"#)
                .map(\.0) == ["alpha"]
        )
    }

    /// Every listed value is read, not just the first: a set-membership test
    /// that saw only its first argument would quietly narrow to an `#eq?`.
    @Test("#any-of? reads all of its arguments")
    func anyOf() throws {
        let found = try highlight(
            "one; two; three; four;",
            javascriptQuery: #"((identifier) @keyword (#any-of? @keyword "two" "four"))"#
        )
        #expect(found.map(\.0) == ["two", "four"])
    }

    @Test("#not-any-of? excludes all of its arguments")
    func notAnyOf() throws {
        let found = try highlight(
            "one; two; three;",
            javascriptQuery: #"((identifier) @keyword (#not-any-of? @keyword "two"))"#
        )
        #expect(found.map(\.0) == ["one", "three"])
    }

    /// tree-sitter stores a `#match?` pattern verbatim without validating it, so
    /// a regex ICU rejects reaches us at match time. It must make the test
    /// unsatisfiable, not absent: emitting the captures unfiltered would colour
    /// exactly what the query asked to filter out.
    @Test("A regex that will not compile drops its captures rather than passing them")
    func uncompilableRegexFailsClosed() throws {
        let found = try highlight(
            "alpha; Beta;",
            javascriptQuery: #"((identifier) @keyword (#match? @keyword "*"))"#
        )
        #expect(found.isEmpty)
    }

    /// An unrecognised predicate stays permissive, which is right for anything
    /// that is not negated -- `#is-not? local` needs a scope resolver we do not
    /// have, and dropping its captures would lose colour rather than add it.
    @Test("An unknown predicate passes")
    func unknownPredicatePasses() throws {
        let found = try highlight(
            "alpha;",
            javascriptQuery: "((identifier) @keyword (#is-not? local))"
        )
        #expect(found.map(\.0) == ["alpha"])
    }

    /// Injection patterns carry predicates like any others, and the unsafe
    /// direction is the permissive one: a region that should not be injected
    /// would be parsed and coloured as another language.
    @Test("Predicates on an injection pattern are evaluated")
    func injectionPredicates() throws {
        let highlights = "(tag_name) @tag"
        let gated = """
        ((script_element
          (raw_text) @injection.content)
         (#eq? @injection.content "const gated = 1;")
         (#set! injection.language "javascript"))
        """
        let queries = try root([
            "html/highlights.scm": highlights,
            "html/injections.scm": gated,
            // The child parser loads from the same root, so the injected
            // language needs a query here too.
            "javascript/highlights.scm": "\"const\" @keyword",
        ])
        defer { try? FileManager.default.removeItem(at: queries) }
        let parser = try #require(SyntaxParser(language: .html, queriesRoot: queries))

        func words(_ source: String) -> [String] {
            let text = source as NSString
            return parser.tokens(for: source).tokens.map { text.substring(with: $0.range) }
        }
        #expect(words("<script>const gated = 1;</script>").contains("const"))
        #expect(!words("<script>const other = 2;</script>").contains("const"))
    }

    /// The `@injection.language` capture form, which names the language in the
    /// document rather than in the query.
    @Test("An injection language given as a capture is honoured")
    func injectionLanguageFromCapture() throws {
        let queries = try root([
            "html/highlights.scm": "(tag_name) @tag",
            "html/injections.scm": """
            (script_element
              (start_tag (attribute (quoted_attribute_value (attribute_value) @injection.language)))
              (raw_text) @injection.content)
            """,
            "javascript/highlights.scm": "\"const\" @keyword",
        ])
        defer { try? FileManager.default.removeItem(at: queries) }
        let parser = try #require(SyntaxParser(language: .html, queriesRoot: queries))
        let source = "<script type=\"javascript\">const n = 1;</script>"
        let text = source as NSString
        let words = parser.tokens(for: source).tokens.map { text.substring(with: $0.range) }
        #expect(words.contains("const"))
    }

    /// A query file that is missing or will not compile leaves the document
    /// plain rather than crashing.
    @Test("A broken or missing query degrades to no parser")
    func brokenQuery() throws {
        let missing = try root([:])
        defer { try? FileManager.default.removeItem(at: missing) }
        #expect(SyntaxParser(language: .javascript, queriesRoot: missing) == nil)

        let broken = try root(["javascript/highlights.scm": "((((not a query"])
        defer { try? FileManager.default.removeItem(at: broken) }
        #expect(SyntaxParser(language: .javascript, queriesRoot: broken) == nil)
    }
}
