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
    public init?(_ text: String, maximumLength: Int) {
        var starts: [Int] = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if offset > maximumLength { return nil }
            // A trailing newline opens a final empty line, so "a\n" is [0, 2].
            if unit == Self.lineFeed { starts.append(offset) }
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
