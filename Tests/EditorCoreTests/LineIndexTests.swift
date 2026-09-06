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
