import Foundation

/// A position in a document, expressed in the three units that matter here.
public struct SourceLocation: Sendable, Equatable {
    /// 1-based, for showing the user.
    public let line: Int
    /// 1-based, counted in Characters.
    public let column: Int
    /// The offset NSTextView and NSTextStorage ranges are actually expressed in.
    public let utf16Offset: Int

    public init(line: Int, column: Int, utf16Offset: Int) {
        self.line = line
        self.column = column
        self.utf16Offset = utf16Offset
    }
}

public enum SourceLocationMapper {
    /// Converts a UTF-8 byte offset into a line, column, and UTF-16 offset.
    ///
    /// This conversion is the sharpest trap in the JSON feature. The Go helper
    /// reports errors as UTF-8 byte offsets; NSTextView and NSTextStorage ranges
    /// are UTF-16 code units. The two agree only for a pure-ASCII prefix, so
    /// skipping this looks perfectly correct in every ASCII test file and drifts
    /// further off the more non-ASCII the document contains.
    public static func locate(byteOffset: Int, in text: String) -> SourceLocation {
        let bytes = Array(text.utf8)
        var end = min(max(byteOffset, 0), bytes.count)

        // Never cut in the middle of a multi-byte scalar: continuation bytes are
        // 0b10xxxxxx, so walk back until the cut point starts a scalar. Otherwise
        // the prefix decodes with a U+FFFD and the UTF-16 count is off by one.
        while end > 0, end < bytes.count, bytes[end] & 0xC0 == 0x80 {
            end -= 1
        }

        let prefix = String(decoding: bytes[0..<end], as: UTF8.self)

        var line = 1
        var column = 1
        for character in prefix {
            if character == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }

        return SourceLocation(line: line, column: column, utf16Offset: prefix.utf16.count)
    }
}
