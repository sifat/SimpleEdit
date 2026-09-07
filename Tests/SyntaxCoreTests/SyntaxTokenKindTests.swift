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
        #expect(SyntaxTokenKind(captureName: "keyword") == nil)
        #expect(SyntaxTokenKind(captureName: "variable.builtin") == nil)
        #expect(SyntaxTokenKind(captureName: "") == nil)
    }
}
