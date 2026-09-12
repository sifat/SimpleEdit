import Foundation
import Testing
@testable import EditorCore

@Suite("Line index")
struct LineIndexTests {

    private let cap = 1_000_000

    @Test("An empty document is one line")
    func empty() {
        let index = LineIndex("", maximumLength: cap)
        #expect(index?.lineStarts == [0])
        #expect(index?.lineCount == 1)
    }

    @Test("Line starts are UTF-16 offsets")
    func simple() {
        #expect(LineIndex("a\nb", maximumLength: cap)?.lineStarts == [0, 2])
    }

    /// The classic off-by-one, pinned deliberately: a trailing newline opens a
    /// final empty line, so "a\n" is two lines. That is VS Code's reading; vim
    /// would say one. Either is defensible, but it has to be decided once.
    @Test("A trailing newline opens a final empty line")
    func trailingNewline() {
        let index = LineIndex("a\n", maximumLength: cap)
        #expect(index?.lineStarts == [0, 2])
        #expect(index?.lineCount == 2)
    }

    /// Same bug class SourceLocationTests guards. An emoji is one Character but
    /// two UTF-16 units, so counting Characters would place every line start
    /// after it one unit early and the gutter would number the wrong rows.
    @Test("Astral characters count as two UTF-16 units")
    func astral() {
        #expect(LineIndex("🎉\n🎉", maximumLength: cap)?.lineStarts == [0, 3])
    }

    /// The empty last line a trailing newline opens is invisible to TextKit 2 --
    /// it lays out no fragment for it -- so the gutter has to know the line is
    /// there in order to number it. Without this the caret sat on an unnumbered
    /// line every time a file ended the way nearly every text file ends.
    @Test("A trailing newline is reported as a trailing empty line")
    func trailingEmptyLine() throws {
        #expect(try #require(LineIndex("alpha\nbravo\n", maximumLength: cap)).hasTrailingEmptyLine)
        #expect(try #require(LineIndex("\n", maximumLength: cap)).hasTrailingEmptyLine)
    }

    @Test("A document not ending in a newline has no trailing empty line")
    func noTrailingEmptyLine() throws {
        #expect(try #require(LineIndex("alpha\nbravo", maximumLength: cap)).hasTrailingEmptyLine == false)
        #expect(try #require(LineIndex("alpha", maximumLength: cap)).hasTrailingEmptyLine == false)
        // The empty document is one line, not a trailing empty one -- the gutter
        // draws that case separately.
        #expect(try #require(LineIndex("", maximumLength: cap)).hasTrailingEmptyLine == false)
    }

    @Test("Length counts UTF-16 units, not Characters")
    func length() throws {
        #expect(try #require(LineIndex("abc", maximumLength: cap)).length == 3)
        #expect(try #require(LineIndex("🎉", maximumLength: cap)).length == 2)
        #expect(try #require(LineIndex("", maximumLength: cap)).length == 0)
    }

    @Test("Consecutive newlines each open a line")
    func blankLines() {
        #expect(LineIndex("\n\n\n", maximumLength: cap)?.lineStarts == [0, 1, 2, 3])
    }

    @Test("Line lookup is 1-based")
    func lookup() throws {
        let index = try #require(LineIndex("a\nbb\nc", maximumLength: cap))
        #expect(index.lineNumber(containing: 0) == 1)
        #expect(index.lineNumber(containing: 1) == 1)
        #expect(index.lineNumber(containing: 2) == 2)
        #expect(index.lineNumber(containing: 5) == 3)
    }

    @Test("Offsets outside the document clamp rather than trapping")
    func outOfRange() throws {
        let index = try #require(LineIndex("a\nb", maximumLength: cap))
        #expect(index.lineNumber(containing: -5) == 1)
        #expect(index.lineNumber(containing: 9_999) == 2)
    }

    /// Bug 2 in v1.0. Over the cap the index became [0], which is a perfectly
    /// valid index meaning "one line", so the gutter labelled every visible row
    /// "1". nil is the only answer that lets the caller tell "too big to index"
    /// apart from "one line".
    @Test("An oversized document has no index at all")
    func overCap() {
        #expect(LineIndex("abcdef", maximumLength: 3) == nil)
    }

    @Test("A document exactly at the cap is still indexed")
    func atCap() {
        #expect(LineIndex("abc", maximumLength: 3)?.lineStarts == [0])
    }

    /// TextKit 2 makes one layout fragment per PARAGRAPH, and the gutter numbers
    /// fragments, so the breaks counted here have to be Foundation's paragraph
    /// separators -- not just LF, which is all a file normalised on read ever
    /// contains, and not the line separators, which break a line without
    /// starting a fragment. Counting only LF was right until the first pasted
    /// CR or U+2029, after which every number below it was off by one.
    @Test("Every paragraph separator opens a line; line separators do not")
    func paragraphSeparators() {
        #expect(LineIndex("a\rb", maximumLength: cap)?.lineStarts == [0, 2])
        #expect(LineIndex("a\r\nb", maximumLength: cap)?.lineStarts == [0, 3])
        #expect(LineIndex("a\u{2029}b", maximumLength: cap)?.lineStarts == [0, 2])
        #expect(LineIndex("a\u{2028}b", maximumLength: cap)?.lineStarts == [0])
        #expect(LineIndex("a\u{0085}b", maximumLength: cap)?.lineStarts == [0])
        // CR CR LF is a lone CR then a CRLF pair: two breaks, not three.
        #expect(LineIndex("a\r\r\nb", maximumLength: cap)?.lineStarts == [0, 2, 4])
        #expect(LineIndex("\r\n", maximumLength: cap)?.lineStarts == [0, 2])
    }

    /// The authority. Whatever Foundation calls a paragraph is what TextKit
    /// lays out as one fragment, so the index must agree with it exactly --
    /// including on which characters are NOT paragraph separators.
    @Test("Line starts agree with Foundation's paragraph starts")
    func agreesWithFoundation() throws {
        let text = "a\nb\rc\r\nd\u{2029}e\u{0085}f\u{2028}g\n\nh"
        let index = try #require(LineIndex(text, maximumLength: cap))
        let ns = text as NSString
        var starts = [0]
        var location = 0
        while location < ns.length {
            var end = 0
            var contentsEnd = 0
            ns.getParagraphStart(
                nil, end: &end, contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            // A terminated paragraph opens the next line, even an empty trailing
            // one; the final unterminated paragraph opens nothing.
            if contentsEnd < end { starts.append(end) }
            location = end
        }
        #expect(index.lineStarts == starts)
    }
}

@Suite("Line index cache")
struct LineIndexCacheTests {

    /// Bug 1 in v1.0. refreshLineIndex marked the index stale and rebuilt it on
    /// the very next line, so a burst of keystrokes cost one full document scan
    /// each while the comment claimed it cost one in total.
    @Test("A burst of invalidations costs one rebuild")
    func burstCostsOneRebuild() {
        var cache = LineIndexCache(maximumLength: 1_000)
        var pulls = 0
        func text() -> String {
            pulls += 1
            return "a\nb"
        }

        cache.invalidate()
        cache.invalidate()
        cache.invalidate()
        _ = cache.index(for: text())
        _ = cache.index(for: text())

        #expect(cache.rebuildCount == 1)
        // The autoclosure is the point of the API: a fresh cache must not even
        // ask for the string, because for the real caller that is a full
        // document copy on every frame.
        #expect(pulls == 1)
    }

    @Test("Each invalidation earns exactly one rebuild")
    func rebuildsAfterInvalidate() {
        var cache = LineIndexCache(maximumLength: 1_000)
        _ = cache.index(for: "a")
        cache.invalidate()
        _ = cache.index(for: "a\nb")
        #expect(cache.rebuildCount == 2)
    }

    @Test("The index follows the text it was last rebuilt from")
    func tracksText() {
        var cache = LineIndexCache(maximumLength: 1_000)
        #expect(cache.index(for: "a")?.lineCount == 1)
        cache.invalidate()
        #expect(cache.index(for: "a\nb")?.lineCount == 2)
    }

    /// Caching the nil matters as much as caching an index: without it an
    /// oversized document rescans up to the cap on every keystroke only to fail
    /// in the same way again.
    @Test("An oversized result is cached like any other")
    func cachesNil() {
        var cache = LineIndexCache(maximumLength: 2)
        var pulls = 0
        func text() -> String {
            pulls += 1
            return "abcdef"
        }

        #expect(cache.index(for: text()) == nil)
        #expect(cache.index(for: text()) == nil)
        #expect(pulls == 1)
        #expect(cache.rebuildCount == 1)
    }
}
