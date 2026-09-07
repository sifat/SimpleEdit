import Foundation
import Testing
@testable import SyntaxCore

/// Asserts on the *text* each token covers rather than raw offsets: an
/// off-by-one then reads as a visibly wrong word instead of a number nobody can
/// check by eye.
@Suite("CSS parsing")
struct CSSParsingTests {

    private func highlight(_ source: String) throws -> [(String, SyntaxTokenKind)] {
        let parser = try #require(
            SyntaxParser(language: .css, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let text = source as NSString
        return parser.tokens(for: source).tokens.map {
            (text.substring(with: $0.range), $0.kind)
        }
    }

    @Test("A rule colours its selector and its property name")
    func basicRule() throws {
        let found = try highlight(".btn { color: red; }")
        #expect(found.contains { $0 == ("btn", .property) })
        #expect(found.contains { $0 == ("color", .property) })
        #expect(found.contains { $0 == (":", .punctuation) })
        // Braces and semicolons are not captured by this query, so they render
        // in the ordinary text colour.
        #expect(!found.contains { $0.0 == "{" })
        #expect(!found.contains { $0.0 == ";" })
    }

    /// The single most important test in this file. tree-sitter parses
    /// `#match?` but does not evaluate it -- that is the caller's job. If
    /// SyntaxParser stopped resolving predicates, the `@variable` pattern would
    /// match EVERY plain value and `block` would be coloured like a custom
    /// property. Both halves are asserted, because only the pair distinguishes
    /// "predicates work" from "nothing matched at all".
    @Test("A #match? predicate is evaluated, not ignored")
    func predicatesAreResolved() throws {
        let found = try highlight("a { display: block; --brand: red; }")
        // Fails the ^-- test, so it is not a variable -- and nothing else
        // captures a plain value, so it gets no token at all.
        #expect(!found.contains { $0.0 == "block" })
        // Passes it. Captured as both @property and @variable, which map to the
        // same kind, so the duplicate collapses to exactly one token.
        #expect(found.filter { $0.0 == "--brand" } .map(\.1) == [.property])
    }

    @Test("A custom property read through var() is coloured too")
    func customPropertyReference() throws {
        let found = try highlight("a { color: var(--brand); }")
        #expect(found.contains { $0 == ("var", .function) })
        #expect(found.contains { $0 == ("--brand", .property) })
    }

    /// The opposite of HTML's attribute_value, which excludes its quotes.
    /// Pinned because the inconsistency is upstream's, and a future reader will
    /// otherwise assume one of the two tests is wrong.
    @Test("A string value includes its quotes, unlike an HTML attribute value")
    func stringIncludesQuotes() throws {
        let found = try highlight("a::after { content: \"hi\"; }")
        #expect(found.filter { $0.1 == .string }.map(\.0) == ["\"hi\""])
    }

    /// `color_value` is captured as `@string.special`, a name nothing claims,
    /// so it reaches `.string` through the dotted-prefix fallback. This is the
    /// only place a real grammar exercises that path.
    @Test("A hex colour falls back to the string kind")
    func hexColour() throws {
        let found = try highlight("a { color: #ff0088; }")
        #expect(found.contains { $0 == ("#ff0088", .string) })
    }

    /// The first place `SyntaxTokenList`'s overlap rule does any work.
    /// `integer_value` covers `10px` including its unit, and `(unit) @type`
    /// captures the `px` nested inside it -- two overlapping captures over the
    /// same text. Outermost wins, so the unit token is dropped and `10px`
    /// colours as one run rather than two abutting ones.
    @Test("A nested unit capture is absorbed by the number around it")
    func numberAndUnit() throws {
        let found = try highlight("a { width: 10px; }")
        #expect(found.filter { $0.1 == .constant }.map(\.0) == ["10px"])
        #expect(!found.contains { $0.0 == "px" })
    }

    @Test("At-rules are keywords")
    func atRule() throws {
        let found = try highlight("@media (min-width: 10px) { a { color: red; } }")
        #expect(found.contains { $0 == ("@media", .keyword) })
        #expect(found.contains { $0 == ("min-width", .property) })
    }

    @Test("Combinators are punctuation, not text")
    func combinators() throws {
        let found = try highlight("div > p + span { color: red; }")
        #expect(found.contains { $0 == (">", .punctuation) })
        #expect(found.contains { $0 == ("+", .punctuation) })
        #expect(found.contains { $0 == ("div", .tag) })
    }

    @Test("Pseudo-classes and attribute selectors are attributes")
    func selectors() throws {
        let found = try highlight("a:hover, input[type=\"text\"] { color: red; }")
        #expect(found.contains { $0 == ("hover", .attribute) })
        #expect(found.contains { $0 == ("type", .attribute) })
    }

    @Test("An id selector colours the name and the hash separately")
    func idSelector() throws {
        let found = try highlight("#main { color: red; }")
        #expect(found.contains { $0 == ("#", .punctuation) })
        #expect(found.contains { $0 == ("main", .property) })
    }

    @Test("A comment is one token including its delimiters")
    func comment() throws {
        let found = try highlight("a { color: red; }\n/* note */\nb { color: red; }")
        #expect(found.filter { $0.1 == .comment }.map(\.0) == ["/* note */"])
    }

    /// The bug class this project has been bitten by twice already. An emoji is
    /// one Character but two UTF-16 units; if anything in the pipeline counted
    /// Characters, every token after it would land two units early.
    @Test("Offsets survive astral characters")
    func astralCharacters() throws {
        let found = try highlight("a::before { content: \"🎉\"; }\n.late { color: red; }")
        #expect(found.contains { $0 == ("late", .property) })
        #expect(found.contains { $0 == ("color", .property) })
    }

    @Test("Malformed input parses without crashing")
    func malformed() throws {
        _ = try highlight("a { color: ")
        _ = try highlight("}}}}")
        _ = try highlight("@@@ {")
    }

    @Test("An empty document has no tokens")
    func empty() throws {
        #expect(try highlight("").isEmpty)
    }
}
