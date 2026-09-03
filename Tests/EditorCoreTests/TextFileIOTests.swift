import Foundation
import Testing
@testable import EditorCore

@Suite("Text file round-tripping")
struct TextFileIOTests {

    @Test("UTF-8 text round-trips byte-identically")
    func utf8RoundTrip() {
        let original = Data("hello wörld\nsecond line\n".utf8)
        let decoded = TextFileIO.decode(original)
        #expect(decoded.encoding == .utf8)
        #expect(decoded.hasBOM == false)
        #expect(TextFileIO.encode(decoded) == original)
    }

    @Test("A BOM survives the round trip")
    func bomRoundTrip() {
        let original = TextFileIO.utf8BOM + Data("x".utf8)
        let decoded = TextFileIO.decode(original)
        #expect(decoded.hasBOM)
        #expect(decoded.text == "x", "the BOM must not leak into the text")
        #expect(TextFileIO.encode(decoded) == original)
    }

    /// Nothing in Foundation preserves CRLF, so if this breaks, every Windows
    /// file the editor touches silently gains mixed line endings.
    @Test("CRLF is normalised in memory and restored on write")
    func crlfRoundTrip() {
        let original = Data("a\r\nb\r\nc".utf8)
        let decoded = TextFileIO.decode(original)

        #expect(decoded.lineEnding == .crlf)
        #expect(decoded.text == "a\nb\nc", "the editor should only ever see LF")
        #expect(TextFileIO.encode(decoded) == original)
    }

    @Test("Classic-Mac CR round-trips")
    func crRoundTrip() {
        let original = Data("a\rb".utf8)
        let decoded = TextFileIO.decode(original)
        #expect(decoded.lineEnding == .cr)
        #expect(decoded.text == "a\nb")
        #expect(TextFileIO.encode(decoded) == original)
    }

    @Test("Text typed into a CRLF file is written back as CRLF")
    func editedCRLFStaysCRLF() {
        var decoded = TextFileIO.decode(Data("a\r\nb".utf8))
        decoded.text += "\nc"  // as if the user pressed Return, which inserts LF
        #expect(TextFileIO.encode(decoded) == Data("a\r\nb\r\nc".utf8))
    }

    @Test(
        "Line ending detection",
        arguments: [
            ("no terminators at all", LineEnding.lf),
            ("unix\n", LineEnding.lf),
            ("windows\r\n", LineEnding.crlf),
            ("classic\r", LineEnding.cr),
            ("mixed\r\nthen\n", LineEnding.crlf),
            ("\n", LineEnding.lf),
        ]
    )
    func lineEndingDetection(input: String, expected: LineEnding) {
        #expect(TextFileIO.detectLineEnding(in: input) == expected)
    }

    @Test("An empty file decodes to empty, not to a failure")
    func emptyFile() {
        let decoded = TextFileIO.decode(Data())
        #expect(decoded.text.isEmpty)
        #expect(TextFileIO.encode(decoded).isEmpty)
    }

    @Test("Undecodable bytes still open rather than failing")
    func invalidBytesStillOpen() {
        // Lone 0x80/0x81 continuation bytes are not valid UTF-8.
        let decoded = TextFileIO.decode(Data([0x41, 0x80, 0x81, 0x42]))
        #expect(!decoded.text.isEmpty, "the editor must never refuse to open a file")
    }
}
