import Foundation

/// The line terminator a file used on disk.
///
/// No system API preserves this — a grep for `lineEnding`/`CRLF` across every
/// Foundation header returns nothing — so we detect it on read, normalise to LF
/// in memory, and re-expand on write. Without that, pressing Return in a CRLF
/// file silently hands the user a mixed-ending file.
public enum LineEnding: String, Sendable, CaseIterable {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"

    public var displayName: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }
}

/// A decoded text file plus everything needed to write it back unchanged.
public struct DecodedText: Sendable, Equatable {
    public var text: String
    public var encoding: String.Encoding
    public var lineEnding: LineEnding
    public var hasBOM: Bool

    public init(
        text: String = "",
        encoding: String.Encoding = .utf8,
        lineEnding: LineEnding = .lf,
        hasBOM: Bool = false
    ) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.hasBOM = hasBOM
    }
}

public enum TextFileIO {
    static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    /// How far into the file we look for a line terminator. A file with no
    /// terminator in its first 64 KB is treated as LF.
    private static let lineEndingProbeBytes = 64 * 1024

    public static func decode(_ data: Data) -> DecodedText {
        let hasBOM = data.starts(with: utf8BOM)
        let body = hasBOM ? data.dropFirst(utf8BOM.count) : data[...]

        let (raw, encoding) = decodeString(Data(body))
        let lineEnding = detectLineEnding(in: raw)

        return DecodedText(
            text: normaliseToLF(raw),
            encoding: encoding,
            lineEnding: lineEnding,
            hasBOM: hasBOM
        )
    }

    /// The bytes to write, and -- through `decoded` -- the encoding they are
    /// actually in.
    ///
    /// `inout` because the encoding can change here. A file opened as CP1252
    /// that has since had an emoji typed into it cannot be written as CP1252;
    /// it falls back to UTF-8 rather than refusing to save. That fallback used
    /// to be silent: the file became UTF-8 on disk while the document still
    /// said CP1252, so deleting the emoji and saving again flipped it back.
    /// The document now learns what it has become, and stays it.
    public static func encode(_ decoded: inout DecodedText) -> Data {
        let text = expand(decoded.text, to: decoded.lineEnding)

        let body: Data
        if let encoded = text.data(using: decoded.encoding) {
            body = encoded
        } else {
            decoded.encoding = .utf8
            body = Data(text.utf8)
        }
        // The BOM is UTF-8's; on any other encoding it would be three stray
        // bytes. A file can decode with one and still not be UTF-8 -- a BOM
        // followed by invalid UTF-8 is read as CP1252 -- so the flag alone is
        // not enough to trust.
        return decoded.hasBOM && decoded.encoding == .utf8 ? utf8BOM + body : body
    }

    // MARK: - Encoding detection

    /// Apple's documented ladder: try UTF-8, then the heavier ICU-backed
    /// detector, then a legacy fallback. Detection is explicitly a guess.
    private static func decodeString(_ data: Data) -> (String, String.Encoding) {
        if let utf8 = String(data: data, encoding: .utf8) {
            return (utf8, .utf8)
        }

        var converted: NSString?
        // Returns a raw UInt where 0 means "could not determine" — checking that
        // before constructing String.Encoding matters, since String.Encoding(rawValue:)
        // will happily wrap a meaningless 0.
        let raw = NSString.stringEncoding(
            for: data,
            encodingOptions: nil,
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if raw != 0, let converted {
            return (converted as String, String.Encoding(rawValue: raw))
        }

        if let latin = String(data: data, encoding: .windowsCP1252) {
            return (latin, .windowsCP1252)
        }

        // Last resort: never fail to open a file. Invalid bytes become U+FFFD.
        return (String(decoding: data, as: UTF8.self), .utf8)
    }

    // MARK: - Line endings

    static func detectLineEnding(in text: String) -> LineEnding {
        let bytes = text.utf8
        var seen = 0
        var previousWasCR = false

        for byte in bytes {
            if previousWasCR {
                return byte == UInt8(ascii: "\n") ? .crlf : .cr
            }
            if byte == UInt8(ascii: "\n") { return .lf }
            if byte == UInt8(ascii: "\r") { previousWasCR = true }

            seen += 1
            if seen >= lineEndingProbeBytes { break }
        }

        // A CR as the very last byte of the probe is still a classic-Mac ending.
        return previousWasCR ? .cr : .lf
    }

    private static let cr = UInt8(ascii: "\r")
    private static let lf = UInt8(ascii: "\n")

    /// Collapses CRLF and lone CR to LF.
    ///
    /// This works on UTF-8 bytes rather than Characters on purpose. Swift treats
    /// "\r\n" as a SINGLE grapheme cluster, so `text.contains("\r")` is false for a
    /// CRLF document and `replacingOccurrences(of: "\n", ...)` will not match the
    /// LF half of one. Doing this at Character level looks right and silently
    /// leaves carriage returns in the user's file.
    ///
    /// Public because the editor applies it to every insertion as well: the
    /// in-memory invariant "LF only" has to hold for pasted text too, or the
    /// re-expansion on write hands back a mixed-ending file.
    public static func normaliseToLF(_ text: String) -> String {
        // Test before allocating. text.utf8 is a lazy view, so this scans without
        // materialising anything; building the array first cost a full copy of
        // every LF document -- which is most of them, on every open and, once
        // autosave lands, on a timer.
        guard text.utf8.contains(cr) else { return text }

        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == cr {
                out.append(lf)
                // Swallow the LF of a CRLF pair so it does not become a blank line.
                if index + 1 < bytes.count, bytes[index + 1] == lf { index += 1 }
            } else {
                out.append(bytes[index])
            }
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The inverse of `normaliseToLF`, and byte-level for the same reason.
    static func expand(_ text: String, to lineEnding: LineEnding) -> String {
        guard lineEnding != .lf else { return text }
        // Nothing to expand in a single-line document, and the common case for a
        // CRLF file that has not been edited yet.
        guard text.utf8.contains(lf) else { return text }

        let replacement = Array(lineEnding.rawValue.utf8)

        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count + text.utf8.count / 8)
        for byte in text.utf8 {
            if byte == lf {
                out.append(contentsOf: replacement)
            } else {
                out.append(byte)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
