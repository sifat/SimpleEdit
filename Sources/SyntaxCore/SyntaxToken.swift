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
            return left.range.length > right.range.length
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
