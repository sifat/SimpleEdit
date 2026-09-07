import Foundation
import Testing
@testable import SyntaxCore

@Suite("Token list")
struct SyntaxTokenListTests {

    private func token(_ location: Int, _ length: Int, _ kind: SyntaxTokenKind = .tag) -> SyntaxToken {
        SyntaxToken(range: NSRange(location: location, length: length), kind: kind)
    }

    @Test("Tokens come back in document order however they went in")
    func sorts() {
        let list = SyntaxTokenList([token(20, 5), token(0, 3), token(10, 2)])
        #expect(list.tokens.map(\.range.location) == [0, 10, 20])
    }

    /// A query cursor promises nothing about capture order, and grammars can
    /// capture nested nodes. The rule is outermost-wins, deterministically.
    /// HTML barely exercises this; the first injected language will.
    @Test("Overlapping tokens are resolved outermost-first")
    func dropsOverlaps() {
        let list = SyntaxTokenList([
            token(0, 10, .comment),   // outer
            token(2, 3, .string),     // nested, dropped
            token(10, 5, .tag),       // abuts the outer one, kept
        ])
        #expect(list.tokens.count == 2)
        #expect(list.tokens[0].kind == .comment)
        #expect(list.tokens[1].kind == .tag)
    }

    @Test("Zero-length tokens are discarded")
    func dropsEmpty() {
        #expect(SyntaxTokenList([token(5, 0)]).isEmpty)
    }

    @Test("A query returns every token it touches, including partial overlaps")
    func partialOverlaps() {
        let list = SyntaxTokenList([token(0, 5), token(10, 5), token(20, 5)])
        // Straddles the tail of the first and the head of the second.
        let hit = list.tokens(in: NSRange(location: 3, length: 9))
        #expect(hit.map(\.range.location) == [0, 10])
    }

    @Test("A token touching only the very first unit of a range counts")
    func boundaryInclusive() {
        let list = SyntaxTokenList([token(0, 5)])
        #expect(list.tokens(in: NSRange(location: 4, length: 1)).count == 1)
        // ...but one that ends exactly where the range starts does not.
        #expect(list.tokens(in: NSRange(location: 5, length: 1)).isEmpty)
    }

    @Test("Queries outside the tokens return nothing rather than trapping")
    func outOfRange() {
        let list = SyntaxTokenList([token(10, 5)])
        #expect(list.tokens(in: NSRange(location: 0, length: 5)).isEmpty)
        #expect(list.tokens(in: NSRange(location: 100, length: 50)).isEmpty)
        #expect(list.tokens(in: NSRange(location: 10, length: 0)).isEmpty)
        #expect(SyntaxTokenList.empty.tokens(in: NSRange(location: 0, length: 10)).isEmpty)
    }
}
