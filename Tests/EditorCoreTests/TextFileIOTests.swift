import Foundation
import Testing
@testable import EditorCore

@Suite("Text file round-tripping")
struct TextFileIOTests {

    @Test("UTF-8 text round-trips byte-identically")
    func utf8RoundTrip() {
        let original = Data("hello wörld\nsecond line\n".utf8)
        var decoded = TextFileIO.decode(original)
        #expect(decoded.encoding == .utf8)
        #expect(decoded.hasBOM == false)
        #expect(TextFileIO.encode(&decoded) == original)
    }

    @Test("A BOM survives the round trip")
    func bomRoundTrip() {
        let original = TextFileIO.utf8BOM + Data("x".utf8)
        var decoded = TextFileIO.decode(original)
        #expect(decoded.hasBOM)
        #expect(decoded.text == "x", "the BOM must not leak into the text")
        #expect(TextFileIO.encode(&decoded) == original)
    }

    /// Nothing in Foundation preserves CRLF, so if this breaks, every Windows
    /// file the editor touches silently gains mixed line endings.
    @Test("CRLF is normalised in memory and restored on write")
    func crlfRoundTrip() {
        let original = Data("a\r\nb\r\nc".utf8)
        var decoded = TextFileIO.decode(original)

        #expect(decoded.lineEnding == .crlf)
        #expect(decoded.text == "a\nb\nc", "the editor should only ever see LF")
        #expect(TextFileIO.encode(&decoded) == original)
    }

    @Test("Classic-Mac CR round-trips")
    func crRoundTrip() {
        let original = Data("a\rb".utf8)
        var decoded = TextFileIO.decode(original)
        #expect(decoded.lineEnding == .cr)
        #expect(decoded.text == "a\nb")
        #expect(TextFileIO.encode(&decoded) == original)
    }

    @Test("Text typed into a CRLF file is written back as CRLF")
    func editedCRLFStaysCRLF() {
        var decoded = TextFileIO.decode(Data("a\r\nb".utf8))
        decoded.text += "\nc"  // as if the user pressed Return, which inserts LF
        #expect(TextFileIO.encode(&decoded) == Data("a\r\nb\r\nc".utf8))
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
        var decoded = TextFileIO.decode(Data())
        #expect(decoded.text.isEmpty)
        #expect(TextFileIO.encode(&decoded).isEmpty)
    }

    /// A file opened as CP1252 that has since had a character typed into it
    /// that CP1252 cannot hold. Refusing to save would be worse; saving as
    /// UTF-8 without saying so is what used to happen, and the next save then
    /// flipped the file back. The fallback is now recorded on the document.
    @Test("An unrepresentable character falls back to UTF-8, and says so")
    func encodingFallbackIsRecorded() {
        var decoded = DecodedText(text: "caf\u{E9} \u{1F389}", encoding: .windowsCP1252)
        let data = TextFileIO.encode(&decoded)
        #expect(decoded.encoding == .utf8)
        #expect(data == Data("caf\u{E9} \u{1F389}".utf8))
        // ...and the next save writes the same bytes rather than flipping back.
        #expect(TextFileIO.encode(&decoded) == data)
    }

    @Test("A representable document keeps its encoding")
    func encodingIsKeptWhenPossible() {
        var decoded = DecodedText(text: "caf\u{E9}", encoding: .windowsCP1252)
        let data = TextFileIO.encode(&decoded)
        #expect(decoded.encoding == .windowsCP1252)
        #expect(data == "caf\u{E9}".data(using: .windowsCP1252))
    }

    /// The BOM flag is read from the leading bytes, independently of the
    /// encoding the rest of the file turned out to be. A BOM in front of
    /// CP1252 bytes would be three stray characters, so it is written only in
    /// front of UTF-8.
    @Test("A BOM is only written in front of UTF-8")
    func bomOnlyForUTF8() {
        var decoded = DecodedText(text: "AB", encoding: .windowsCP1252, hasBOM: true)
        #expect(!TextFileIO.encode(&decoded).starts(with: TextFileIO.utf8BOM))
        var utf8 = DecodedText(text: "AB", encoding: .utf8, hasBOM: true)
        #expect(TextFileIO.encode(&utf8).starts(with: TextFileIO.utf8BOM))
    }

    /// Recorded, not endorsed. detectLineEnding stops at the first terminator
    /// and expand converts every LF, so a mixed-ending file is rewritten
    /// wholesale to the first kind seen, on lines the user never touched. The
    /// README says so; this pins that it is still what happens.
    @Test("A mixed-ending file is rewritten to its first ending")
    func mixedEndingsAreUnified() {
        var decoded = TextFileIO.decode(Data("a\r\nb\nc".utf8))
        #expect(decoded.lineEnding == .crlf)
        #expect(TextFileIO.encode(&decoded) == Data("a\r\nb\r\nc".utf8))
    }

    @Test("Undecodable bytes still open rather than failing")
    func invalidBytesStillOpen() {
        // Lone 0x80/0x81 continuation bytes are not valid UTF-8.
        let decoded = TextFileIO.decode(Data([0x41, 0x80, 0x81, 0x42]))
        #expect(!decoded.text.isEmpty, "the editor must never refuse to open a file")
    }
}
