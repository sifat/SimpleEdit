import Testing
@testable import EditorCore

@Suite("Byte offset to UTF-16 mapping")
struct SourceLocationTests {

    @Test("ASCII: byte offset and UTF-16 offset agree")
    func asciiOffsetsAgree() {
        let text = "{\n  \"a\": 1\n}"
        let location = SourceLocationMapper.locate(byteOffset: 6, in: text)
        #expect(location.utf16Offset == 6)
        #expect(location.line == 2)
        #expect(location.column == 5)
    }

    /// The bug this whole type exists to prevent. Every character before the
    /// error here is 2 bytes but 1 UTF-16 unit, so a naive implementation that
    /// hands the byte offset straight to NSTextView lands 5 characters late.
    @Test("Non-ASCII: byte offset and UTF-16 offset diverge")
    func nonASCIIOffsetsDiverge() {
        let text = "\"ünïcödé\": oops"
        let byteOffset = Array(text.utf8).count - 4  // start of "oops"
        let location = SourceLocationMapper.locate(byteOffset: byteOffset, in: text)

        #expect(location.utf16Offset == text.utf16.count - 4)
        #expect(location.utf16Offset != byteOffset, "the test is meaningless if these match")
    }

    @Test("Emoji count as two UTF-16 units")
    func surrogatePairs() {
        let text = "🎉🎉x"
        let byteOffset = 8  // after both emoji, each 4 UTF-8 bytes
        let location = SourceLocationMapper.locate(byteOffset: byteOffset, in: text)
        #expect(location.utf16Offset == 4)
        #expect(location.column == 3)
    }

    @Test("Line and column count from one")
    func lineAndColumnAreOneBased() {
        let start = SourceLocationMapper.locate(byteOffset: 0, in: "abc\ndef")
        #expect(start.line == 1)
        #expect(start.column == 1)

        let secondLine = SourceLocationMapper.locate(byteOffset: 5, in: "abc\ndef")
        #expect(secondLine.line == 2)
        #expect(secondLine.column == 2)
    }

    @Test("Offsets outside the document are clamped, not trapped")
    func outOfRangeIsClamped() {
        let text = "hello"
        #expect(SourceLocationMapper.locate(byteOffset: -5, in: text).utf16Offset == 0)
        #expect(SourceLocationMapper.locate(byteOffset: 9_999, in: text).utf16Offset == 5)
    }

    @Test("A cut inside a multi-byte scalar does not corrupt the count")
    func cutInsideScalar() {
        let text = "é"  // 2 UTF-8 bytes, 1 UTF-16 unit
        let location = SourceLocationMapper.locate(byteOffset: 1, in: text)
        #expect(location.utf16Offset == 0)
    }
}
