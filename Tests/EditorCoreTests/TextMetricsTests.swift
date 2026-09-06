import Testing
@testable import EditorCore

@Suite("Text metrics")
struct TextMetricsTests {

    @Test("An empty document has nothing to measure")
    func empty() {
        #expect(TextMetrics.longestLineLength(in: "", stoppingAbove: 100) == 0)
    }

    @Test("Blank lines measure zero")
    func blankLines() {
        #expect(TextMetrics.longestLineLength(in: "\n\n\n", stoppingAbove: 100) == 0)
    }

    @Test("The longest line wins regardless of where it is")
    func longest() {
        #expect(TextMetrics.longestLineLength(in: "a\nbbbb\ncc", stoppingAbove: 100) == 4)
    }

    @Test("A document with no trailing newline still measures its last line")
    func noTrailingNewline() {
        #expect(TextMetrics.longestLineLength(in: "a\nbbb", stoppingAbove: 100) == 3)
    }

    /// The contract worth pinning: above the limit the answer is whichever line
    /// crossed it, NOT the true maximum. Here the real longest line is 50 bytes
    /// and the function returns 5, because it stopped as soon as the question
    /// callers actually ask -- "is anything longer than the limit?" -- was
    /// answered.
    @Test("Above the limit the scan stops and the result is not the true maximum")
    func earlyOut() {
        let text = "aaaaa\n" + String(repeating: "b", count: 50)
        #expect(TextMetrics.longestLineLength(in: text, stoppingAbove: 3) == 5)
    }

    /// It counts UTF-8 bytes, not Characters.
    @Test("Multi-byte characters count as their byte length")
    func bytes() {
        #expect(TextMetrics.longestLineLength(in: "é", stoppingAbove: 100) == 2)
    }
}
