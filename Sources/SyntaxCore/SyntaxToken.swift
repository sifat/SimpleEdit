import Foundation

/// One coloured run. The range is in **UTF-16 code units**, which is what
/// NSTextStorage, NSRange and TextKit 2 all speak -- and, conveniently, what
/// SwiftTreeSitter reports, since it parses UTF-16LE end to end. No conversion
/// happens anywhere in this pipeline, and none should be added.
public struct SyntaxToken: Sendable, Equatable {
    public let range: NSRange
    public let kind: SyntaxTokenKind

    public init(range: NSRange, kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Tokens for one document, sorted and non-overlapping, queryable by range.
///
/// A plain sorted array rather than an interval tree: once the tokens are
/// disjoint, a range query is two binary searches and a slice, with no
/// allocation. The interesting work is the normalising, not the searching.
public struct SyntaxTokenList: Sendable, Equatable {

    public private(set) var tokens: [SyntaxToken]

    public var isEmpty: Bool { tokens.isEmpty }
    public var count: Int { tokens.count }

    public static let empty = SyntaxTokenList([])

    /// Sorts and removes overlaps, outermost-first.
    ///
    /// A query cursor makes no promise about capture order, and grammars can
    /// capture nested nodes. Sorting by (location, longest-first) and then
    /// dropping anything that starts before the previous token ends gives
    /// "outermost wins", deterministically.
    ///
    /// For HTML today this is very nearly a no-op -- its seven captures do not
    /// nest in practice. It is written and tested now because the first
    /// injected language (CSS or JavaScript inside HTML) makes it load-bearing,
    /// and that is a bad moment to discover the rule was wrong.
    public init(_ unsorted: [SyntaxToken]) {
        let sorted = unsorted.sorted { left, right in
            if left.range.location != right.range.location {
                return left.range.location < right.range.location
            }
            if left.range.length != right.range.length {
                return left.range.length > right.range.length
            }
            // Two tokens over the IDENTICAL range: the first one kept wins, so
            // the order here is a decision, and it used to be an accident --
            // Swift's sort is not stable, so the winner was whichever an
            // unstable sort happened to leave first.
            //
            // The rule is that weaker evidence loses. Two kinds are weak:
            //
            // - `.punctuation`, because a token that is punctuation AND
            //   something else is that something else. CSS's `*` is captured
            //   as both an operator and a universal selector; it is a selector,
            //   and colours as one.
            // - `.constant`, because the only way a constant ties with another
            //   kind is through a naming-convention guess -- `^[A-Z][A-Z_]*$`
            //   on an identifier -- while `.type`, `.function` and `.property`
            //   come from the identifier's syntactic position. Literal
            //   constants (numbers, `true`, the doctype) never share a range
            //   with anything. The cases that forced it: Python's single-letter
            //   type variable, `T` in `def f(x: T) -> T`, and JavaScript's
            //   `const MIN_SIZE = () => 1`, which is a function.
            //
            // Measured against the previous behaviour over every token in fifty
            // real stylesheets and the JS, TS and HTML fixtures: the only output
            // that changed is the JavaScript case above.
            let leftRank = left.kind.tieRank
            let rightRank = right.kind.tieRank
            if leftRank != rightRank { return leftRank > rightRank }
            // Ties between two strong kinds do not occur in any vendored
            // grammar. They are ordered by name only so that the result never
            // depends on the order captures happened to arrive in.
            return left.kind.rawValue < right.kind.rawValue
        }

        var kept: [SyntaxToken] = []
        kept.reserveCapacity(sorted.count)
        var reachedEnd = 0
        for token in sorted where token.range.length > 0 {
            guard token.range.location >= reachedEnd else { continue }
            kept.append(token)
            reachedEnd = NSMaxRange(token.range)
        }
        tokens = kept
    }

    /// Every token intersecting `range`, including ones only partly inside it.
    ///
    /// Called from the text view's layout pass, once per visible fragment, so it
    /// must not allocate: the result is a slice into the existing storage.
    public func tokens(in range: NSRange) -> ArraySlice<SyntaxToken> {
        guard !tokens.isEmpty, range.length > 0 else { return [] }

        // First token that ends after the range begins.
        var low = 0
        var high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(tokens[mid].range) <= range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let first = low

        // One past the last token that starts before the range ends.
        let rangeEnd = NSMaxRange(range)
        low = first
        high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if tokens[mid].range.location < rangeEnd {
                low = mid + 1
            } else {
                high = mid
            }
        }

        return tokens[first..<low]
    }
}

extension SyntaxTokenKind {
    /// How much a kind is to be believed when it shares an identical range with
    /// another. Higher wins. See `SyntaxTokenList.init`.
    fileprivate var tieRank: Int {
        switch self {
        case .punctuation: 0
        case .constant: 1
        default: 2
        }
    }
}
