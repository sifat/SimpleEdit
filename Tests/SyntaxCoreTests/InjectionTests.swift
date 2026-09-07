import Foundation
import Testing
@testable import SyntaxCore

/// `<script>` and `<style>` bodies, highlighted by the language they actually
/// contain.
///
/// The HTML grammar hands those bodies over as one opaque `raw_text` node, so
/// everything here depends on running a second query, sub-parsing the region
/// with another grammar, and shifting the results back into the outer
/// document's offsets. Most of these tests are really about that shift.
@Suite("Embedded script and style")
struct InjectionTests {

    private func highlight(_ source: String) throws -> [(String, SyntaxTokenKind)] {
        let parser = try #require(
            SyntaxParser(language: .html, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let text = source as NSString
        return parser.tokens(for: source).tokens.map {
            (text.substring(with: $0.range), $0.kind)
        }
    }

    @Test("A script body is highlighted as JavaScript")
    func scriptBody() throws {
        let found = try highlight("<script>const n = 42;</script>")
        #expect(found.contains { $0 == ("script", .tag) })
        #expect(found.contains { $0 == ("const", .keyword) })
        #expect(found.contains { $0 == ("42", .constant) })
    }

    @Test("A style body is highlighted as CSS")
    func styleBody() throws {
        let found = try highlight("<style>.btn { color: #fff; }</style>")
        #expect(found.contains { $0 == ("style", .tag) })
        #expect(found.contains { $0 == ("btn", .property) })
        #expect(found.contains { $0 == ("color", .property) })
        #expect(found.contains { $0 == ("#fff", .string) })
    }

    /// The offset shift, stated as plainly as it can be: the same construct
    /// appears twice, and both copies have to be found at their own positions.
    @Test("Injected offsets are the document's, not the fragment's")
    func offsetsAreDocumentRelative() throws {
        let source = "<p>a</p><script>const q = 1;</script><p>b</p><script>const q = 2;</script>"
        let text = source as NSString
        let parser = try #require(
            SyntaxParser(language: .html, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let keywords = parser.tokens(for: source).tokens.filter { $0.kind == .keyword }
        #expect(keywords.count == 2)
        for token in keywords {
            #expect(text.substring(with: token.range) == "const")
        }
        // ...and the second is found where the second script actually is.
        #expect(keywords.last?.range.location == (source as NSString).range(of: "const", options: .backwards).location)
    }

    /// The bug class this project has been bitten by twice. An emoji before the
    /// script shifts every offset inside it by two UTF-16 units; an emoji
    /// inside shifts everything after it. Both are covered here because the
    /// slice and the shift are different code paths.
    @Test("Injected offsets survive astral characters")
    func astralCharacters() throws {
        let found = try highlight("<p>🎉</p><script>const flag = \"🎉\"; let after = 7;</script>")
        #expect(found.contains { $0 == ("const", .keyword) })
        #expect(found.contains { $0 == ("\"🎉\"", .string) })
        #expect(found.contains { $0 == ("7", .constant) })
        #expect(found.contains { $0 == ("let", .keyword) })
    }

    @Test("Both languages can be injected into one document")
    func bothAtOnce() throws {
        let found = try highlight("""
        <style>.a { color: red; }</style>
        <script>const b = 1;</script>
        """)
        #expect(found.contains { $0 == ("color", .property) })
        #expect(found.contains { $0 == ("const", .keyword) })
    }

    /// An empty body still produces an injection, of length zero. Slicing one
    /// is harmless and parsing it is pure cost, so they are skipped -- but the
    /// surrounding markup must still be coloured.
    @Test("An empty or src-only script is not an error")
    func emptyBodies() throws {
        for source in ["<script></script>", "<script src=\"a.js\"></script>", "<style></style>"] {
            let found = try highlight(source)
            #expect(found.contains { $0.1 == .tag })
        }
    }

    /// A script inside a comment is not a script. The HTML grammar puts the
    /// whole comment in one node, so no injection is produced at all.
    @Test("A script inside a comment is not injected")
    func scriptInsideComment() throws {
        let found = try highlight("<!-- <script>const n = 1;</script> -->")
        #expect(found.filter { $0.1 == .comment }.count == 1)
        #expect(!found.contains { $0 == ("const", .keyword) })
    }

    /// The outer document must not be able to swallow the inner one. Every node
    /// the HTML query captures is a leaf except the doctype, which cannot
    /// contain an element, so no HTML token can be an ancestor of an injected
    /// one -- and the merge rule is outermost-wins.
    @Test("Parent tokens never swallow injected ones")
    func noParentOverlap() throws {
        let source = """
        <!DOCTYPE html>
        <html><head><style>a { color: red; }</style></head>
        <body class="x"><script>const n = 1;</script></body></html>
        """
        let parser = try #require(
            SyntaxParser(language: .html, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let tokens = parser.tokens(for: source).tokens
        for (left, right) in zip(tokens, tokens.dropFirst()) {
            #expect(NSMaxRange(left.range) <= right.range.location)
        }
        let text = source as NSString
        let words = tokens.map { text.substring(with: $0.range) }
        #expect(words.contains("color"))
        #expect(words.contains("const"))
        #expect(words.contains("<!DOCTYPE html>"))
    }

    /// A `</script>` inside a JavaScript string ends the element as far as HTML
    /// is concerned -- that is HTML's rule, not a bug here. Pinned so the
    /// behaviour is known rather than discovered.
    @Test("Malformed and adversarial embedding does not crash")
    func adversarial() throws {
        _ = try highlight("<script>const s = \"</script>\";</script>")
        _ = try highlight("<script>/* unterminated")
        _ = try highlight("<style>.a { color:")
        _ = try highlight("<script><script><script>")
    }

    /// Only HTML injects. A stylesheet that happens to contain the text
    /// `<script>` must not start sub-parsing.
    @Test("Only HTML carries an injections query")
    func onlyHTMLInjects() {
        #expect(SyntaxLanguage.html.injectionQueryFile != nil)
        for language in SyntaxLanguage.allCases where language != .html {
            #expect(language.injectionQueryFile == nil)
        }
    }

    @Test("Injection language names map to the languages we have")
    func injectionNames() {
        #expect(SyntaxLanguage(injectionName: "javascript") == .javascript)
        #expect(SyntaxLanguage(injectionName: "css") == .css)
        // A name from a grammar we do not have leaves the region plain.
        #expect(SyntaxLanguage(injectionName: "python") == nil)
        #expect(SyntaxLanguage(injectionName: "JavaScript") == nil)
    }
}
