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

    /// Two tokens over the identical range: the winner is a decision. A
    /// constant that ties comes from a naming-convention guess, so position
    /// evidence (`.type`, `.function`) beats it -- in either input order.
    @Test("On an identical range, a constant loses")
    func constantLosesTies() {
        for kind in [SyntaxTokenKind.type, .function, .property] {
            #expect(SyntaxTokenList([token(0, 1, .constant), token(0, 1, kind)]).tokens.map(\.kind) == [kind])
            #expect(SyntaxTokenList([token(0, 1, kind), token(0, 1, .constant)]).tokens.map(\.kind) == [kind])
        }
    }

    /// A token that is punctuation AND something else is that something else:
    /// CSS's universal selector `*` is also captured as an operator.
    @Test("On an identical range, punctuation loses, even to a constant")
    func punctuationLosesTies() {
        #expect(SyntaxTokenList([token(0, 1, .punctuation), token(0, 1, .tag)]).tokens.map(\.kind) == [.tag])
        #expect(SyntaxTokenList([token(0, 1, .tag), token(0, 1, .punctuation)]).tokens.map(\.kind) == [.tag])
        #expect(SyntaxTokenList([token(0, 1, .punctuation), token(0, 1, .constant)]).tokens.map(\.kind) == [.constant])
    }

    /// Ties between two strong kinds do not occur in any vendored grammar, but
    /// if one did the result must not depend on capture arrival order.
    @Test("Any remaining tie is independent of input order")
    func tiesAreDeterministic() {
        let a = SyntaxTokenList([token(0, 3, .keyword), token(0, 3, .function)])
        let b = SyntaxTokenList([token(0, 3, .function), token(0, 3, .keyword)])
        #expect(a == b)
    }

    /// The rule only breaks ties. Outermost-wins is untouched: a longer token
    /// still swallows a shorter one inside it, whatever their kinds.
    @Test("Ranks never override outermost-wins")
    func ranksOnlyBreakTies() {
        let list = SyntaxTokenList([token(0, 4, .constant), token(2, 2, .type)])
        #expect(list.tokens.map(\.kind) == [.constant])
    }
}
