import Foundation

/// Decides when the line index is rebuilt.
///
/// This is its own type because the policy is where the bug was. v1.0 marked the
/// index stale and then rebuilt it on the very next line, so every keystroke paid
/// a full document scan while the comment above it claimed a burst of keystrokes
/// cost one. Policy in a struct can be tested; policy inside an NSRulerView
/// cannot.
public struct LineIndexCache {

    private var cached: LineIndex?
    private var isStale = true
    private let maximumLength: Int

    /// How many rebuilds have actually happened. Exists for tests -- it is the
    /// only way to observe the coalescing from outside.
    public private(set) var rebuildCount = 0

    public init(maximumLength: Int) {
        self.maximumLength = maximumLength
    }

    public mutating func invalidate() {
        isStale = true
    }

    /// The current index, rebuilding only if something invalidated it.
    ///
    /// `text` is an autoclosure on purpose. The caller is a draw pass and the
    /// argument is `textView.string`, which copies the whole document; evaluating
    /// it eagerly would cost a full copy on every frame while scrolling, with
    /// nothing stale and nothing to rebuild.
    ///
    /// A nil result is cached like any other, so an oversized document is not
    /// rescanned up to the cap on every keystroke only to fail the same way.
    public mutating func index(for text: @autoclosure () -> String) -> LineIndex? {
        guard isStale else { return cached }
        isStale = false
        rebuildCount += 1
        cached = LineIndex(text(), maximumLength: maximumLength)
        return cached
    }
}
