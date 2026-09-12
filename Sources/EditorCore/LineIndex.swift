import Foundation

/// Where every logical line begins, as a UTF-16 offset.
///
/// UTF-16 because that is the unit NSTextView, NSRange and NSTextRange all speak.
/// Counting Characters or UTF-8 bytes here looks correct on ASCII and drifts on
/// everything else -- the same trap SourceLocationMapper exists to solve.
public struct LineIndex: Sendable, Equatable {

    /// Always non-empty: a document with no newlines is one line starting at 0.
    public let lineStarts: [Int]

    /// Total length of the indexed text, in UTF-16 code units.
    public let length: Int

    public var lineCount: Int { lineStarts.count }

    /// True when the document ends with a newline, so its last line is empty.
    ///
    /// Worth naming because that line is invisible to the layout system: TextKit
    /// 2 produces no layout fragment for it, so a ruler walking fragments will
    /// never be handed anything to label, and the caret ends up sitting on an
    /// unnumbered line. Whoever draws the numbers has to place this one itself.
    public var hasTrailingEmptyLine: Bool {
        lineStarts.count > 1 && lineStarts[lineStarts.count - 1] == length
    }

    private static let lineFeed: UInt16 = 0x000A
    private static let carriageReturn: UInt16 = 0x000D
    private static let paragraphSeparator: UInt16 = 0x2029

    /// Builds the index, or returns nil if the document is longer than
    /// `maximumLength` UTF-16 units.
    ///
    /// nil means "too big to index", which is deliberately NOT the same as "one
    /// line". Returning a degenerate `[0]` for an oversized document is what made
    /// the v1.0 gutter label every visible row "1"; only nil lets the caller tell
    /// the two apart and draw nothing.
    ///
    /// The size check happens during the scan rather than up front, so an
    /// oversized document stops after `maximumLength` units instead of being
    /// walked to the end to learn something we already know.
    ///
    /// A "line" here is what TextKit calls a paragraph, because that is what the
    /// gutter numbers: TextKit 2 produces one layout fragment per paragraph, and
    /// the ruler maps each fragment's offset through `lineNumber(containing:)`.
    /// So the breaks counted are exactly Foundation's paragraph separators --
    /// LF, CR, CRLF as one, and U+2029 -- and not its line separators (U+2028,
    /// U+0085), which break a line inside a paragraph without starting a new
    /// fragment. Counting only LF looked right because files are normalised to
    /// LF on read; text pasted from elsewhere is not, and every number below
    /// the first stray CR or U+2029 was then off by one. Pinned against
    /// `NSString.getParagraphStart` in the tests.
    public init?(_ text: String, maximumLength: Int) {
        var starts: [Int] = [0]
        var offset = 0
        var previousWasCR = false
        for unit in text.utf16 {
            offset += 1
            if offset > maximumLength { return nil }
            switch unit {
            case Self.lineFeed:
                // The LF of a CRLF pair: the CR already opened the line, one
                // unit early. Move that start rather than adding a second.
                if previousWasCR {
                    starts[starts.count - 1] = offset
                } else {
                    // A trailing newline opens a final empty line, so "a\n"
                    // is [0, 2].
                    starts.append(offset)
                }
            case Self.carriageReturn, Self.paragraphSeparator:
                starts.append(offset)
            default:
                break
            }
            previousWasCR = unit == Self.carriageReturn
        }
        lineStarts = starts
        length = offset
    }

    /// Which 1-based line contains this UTF-16 offset.
    ///
    /// Offsets outside the document clamp to the first or last line rather than
    /// trapping: the caller is a draw pass, and crashing the app is a worse
    /// answer than a wrong line number.
    public func lineNumber(containing utf16Offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= utf16Offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }
}
