import Foundation

public enum TextMetrics {

    /// Length of the longest line, in UTF-8 bytes, giving up once the answer
    /// exceeds `limit`.
    ///
    /// Two things the name does not say, both deliberate.
    ///
    /// It counts BYTES, not Characters. That is right for deciding whether to
    /// wrap and wrong for anything resembling a column number.
    ///
    /// Once the result is above `limit` it is NOT the true maximum -- the scan
    /// stops at the first line that crosses. Every caller only asks whether the
    /// threshold was crossed, and walking a 50 MB minified file to the end to
    /// produce a number nobody reads would defeat the purpose of asking.
    public static func longestLineLength(in text: String, stoppingAbove limit: Int) -> Int {
        var longest = 0
        var current = 0
        for byte in text.utf8 {
            if byte == UInt8(ascii: "\n") {
                longest = max(longest, current)
                current = 0
                if longest > limit { return longest }
            } else {
                current += 1
            }
        }
        return max(longest, current)
    }
}
