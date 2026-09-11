import Foundation
import Testing
@testable import SyntaxCore

/// Asserts on the *text* each token covers rather than raw offsets: an
/// off-by-one then reads as a visibly wrong word instead of a number nobody can
/// check by eye.
@Suite("HTML parsing")
struct HTMLParsingTests {

    private static var queriesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Queries", isDirectory: true)
    }

    private func highlight(_ source: String) throws -> [(String, SyntaxTokenKind)] {
        let parser = try #require(SyntaxParser(language: .html, queriesRoot: Self.queriesRoot))
        let text = source as NSString
        return parser.tokens(for: source).tokens.map {
            (text.substring(with: $0.range), $0.kind)
        }
    }

    @Test("Tags, attributes and values, in order")
    func basicElement() throws {
        let found = try highlight("<div class=\"a\">x</div>")
        #expect(found.map(\.0) == ["<", "div", "class", "a", ">", "</", "div", ">"])
        #expect(found.map(\.1) == [
            .punctuation, .tag, .attribute, .string, .punctuation,
            .punctuation, .tag, .punctuation,
        ])
        // Body text is not captured by the HTML grammar, so `x` gets no token
        // and renders in the ordinary text colour.
        #expect(!found.contains { $0.0 == "x" })
    }

    /// The attribute_value node excludes its quotes, so the string token covers
    /// `a` and not `"a"`. Pinned because a theme that colours the quotes would
    /// look wrong and the cause would be non-obvious.
    @Test("Quote characters are outside the string token")
    func quotesExcluded() throws {
        let found = try highlight("<a href=\"x\">")
        let strings = found.filter { $0.1 == .string }.map(\.0)
        #expect(strings == ["x"])
    }

    @Test("An empty attribute value produces no string token at all")
    func emptyAttributeValue() throws {
        let found = try highlight("<div class=\"\">")
        #expect(found.filter { $0.1 == .string }.isEmpty)
        #expect(found.contains { $0 == ("class", .attribute) })
    }

    @Test("A comment is one token including its delimiters")
    func comment() throws {
        let found = try highlight("<p>a</p><!-- hi --><p>b</p>")
        let comments = found.filter { $0.1 == .comment }.map(\.0)
        #expect(comments == ["<!-- hi -->"])
    }

    @Test("The doctype is one constant including its angle brackets")
    func doctype() throws {
        let found = try highlight("<!DOCTYPE html>\n<p>x</p>")
        let constants = found.filter { $0.1 == .constant }.map(\.0)
        #expect(constants == ["<!DOCTYPE html>"])
    }

    /// The bug class this project has been bitten by twice already. An emoji is
    /// one Character but two UTF-16 units; if anything in the pipeline counted
    /// Characters, `href` would land one unit early and colour the wrong text.
    @Test("Offsets survive astral characters")
    func astralCharacters() throws {
        let found = try highlight("<p>🎉</p><a href=\"x\">")
        #expect(found.contains { $0 == ("href", .attribute) })
        #expect(found.contains { $0 == ("x", .string) })
        #expect(found.contains { $0 == ("a", .tag) })
    }

    /// The counterpart of the injection tests: a `<` inside a script body is a
    /// less-than operator, not markup. Before injections it produced no token
    /// at all; now it is coloured by the JavaScript grammar, which is the same
    /// answer for a better reason.
    @Test("A < inside a script body is an operator, not a tag bracket")
    func lessThanInsideScript() throws {
        let found = try highlight("<script>let x = 1 < 2;</script>")
        #expect(found.contains { $0 == ("script", .tag) })
        #expect(found.contains { $0 == ("let", .keyword) })
        // `<` is captured by JavaScript as an operator, which this app colours
        // as punctuation -- the same kind an HTML angle bracket gets, but
        // arrived at through the right grammar.
        #expect(found.contains { $0 == ("<", .punctuation) })
        #expect(!found.contains { $0.0 == "x" })
    }

    @Test("Malformed input parses without crashing")
    func malformed() throws {
        _ = try highlight("<div <<< >")
        _ = try highlight("</unopened>")
        _ = try highlight("<<<<")
    }

    @Test("An empty document has no tokens")
    func empty() throws {
        #expect(try highlight("").isEmpty)
    }
}
