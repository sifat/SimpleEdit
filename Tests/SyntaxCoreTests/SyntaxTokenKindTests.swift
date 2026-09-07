import Testing
@testable import SyntaxCore

@Suite("Capture names to token kinds")
struct SyntaxTokenKindTests {

    @Test("The HTML grammar's capture names all map")
    func htmlCaptureNames() {
        #expect(SyntaxTokenKind(captureName: "tag") == .tag)
        #expect(SyntaxTokenKind(captureName: "attribute") == .attribute)
        #expect(SyntaxTokenKind(captureName: "string") == .string)
        #expect(SyntaxTokenKind(captureName: "comment") == .comment)
        #expect(SyntaxTokenKind(captureName: "constant") == .constant)
    }

    @Test("The CSS grammar's capture names all map")
    func cssCaptureNames() {
        #expect(SyntaxTokenKind(captureName: "keyword") == .keyword)
        #expect(SyntaxTokenKind(captureName: "property") == .property)
        #expect(SyntaxTokenKind(captureName: "function") == .function)
    }

    /// Four capture names deliberately land on a kind that already existed.
    /// Written out one by one because each is a judgement call rather than an
    /// oversight, and a future reader deleting one would change what the editor
    /// looks like without touching any code that mentions colour.
    @Test("Some CSS captures deliberately share a kind with something else")
    func deliberateCollapses() {
        // A CSS custom property (--brand) is a property.
        #expect(SyntaxTokenKind(captureName: "variable") == .property)
        // A number and the unit stuck to it are both literal values.
        #expect(SyntaxTokenKind(captureName: "number") == .constant)
        #expect(SyntaxTokenKind(captureName: "type") == .constant)
        // Combinators are punctuation that happens to mean something.
        #expect(SyntaxTokenKind(captureName: "operator") == .punctuation)
        // And a hex colour reaches .string the same way punctuation.bracket
        // reaches .punctuation -- nothing claims the full dotted name.
        #expect(SyntaxTokenKind(captureName: "string.special") == .string)
    }

    /// tree-sitter names are hierarchical and an unclaimed leaf falls back to
    /// its parent. `punctuation.bracket` is the only dotted name HTML actually
    /// emits, and nothing claims it specifically.
    @Test("A dotted name falls back to its parent")
    func dottedFallback() {
        #expect(SyntaxTokenKind(captureName: "punctuation.bracket") == .punctuation)
        #expect(SyntaxTokenKind(captureName: "punctuation.delimiter.special") == .punctuation)
    }

    /// ...but a longer match wins, which is how a mismatched closing tag gets
    /// its own colour instead of looking like an ordinary tag.
    @Test("A more specific name beats its parent")
    func longestMatchWins() {
        #expect(SyntaxTokenKind(captureName: "tag") == .tag)
        #expect(SyntaxTokenKind(captureName: "tag.error") == .invalid)
    }

    /// The degradation path: a grammar bump that introduces a capture nobody
    /// has mapped leaves that text uncoloured rather than breaking.
    @Test("An unknown name maps to nothing rather than guessing")
    func unknownNames() {
        #expect(SyntaxTokenKind(captureName: "constructor") == nil)
        #expect(SyntaxTokenKind(captureName: "markup.heading") == nil)
        #expect(SyntaxTokenKind(captureName: "") == nil)
    }
}
