import Foundation

/// Decides whether to attempt highlighting after the time budget has cut it.
///
/// A document that cannot be tokenised inside the budget -- deep nesting, an
/// unbalanced bracket a long way from its partner -- would otherwise pay the
/// whole budget on every keystroke, each time discovering the same thing. The
/// incremental parse cannot help it: a parse that never finished has no tree
/// to reuse. So after a cut, attempts are spaced out: the next keystroke is
/// skipped, then three, then seven, and from there every eighth keystroke is
/// tried. A hostile document costs roughly a tenth of the budget per keystroke
/// instead of all of it, and colour returns within eight keystrokes of the
/// text becoming parseable again -- the moment an attempt succeeds, the
/// spacing resets to zero.
///
/// A value type with no clock, so it is testable as a table of decisions.
public struct CutBackoff: Equatable, Sendable {
    /// Keystrokes to let pass before the next attempt. At most seven.
    public static let maximumSkips = 7

    private var consecutiveCuts = 0
    private var skipsRemaining = 0

    public init() {}

    /// Called once per keystroke. True means "try now"; false means "leave
    /// the document as it is, and do no work".
    public mutating func shouldAttempt() -> Bool {
        guard skipsRemaining > 0 else { return true }
        skipsRemaining -= 1
        return false
    }

    /// The outcome of an attempt `shouldAttempt()` allowed.
    public mutating func record(cut: Bool) {
        guard cut else {
            consecutiveCuts = 0
            skipsRemaining = 0
            return
        }
        consecutiveCuts += 1
        // 1, 3, 7, 7, 7 ... -- doubling, capped, so a document that is hostile
        // for a long time settles at one attempt in eight.
        skipsRemaining = min((1 << consecutiveCuts) - 1, Self.maximumSkips)
    }

    /// For a document that has just been replaced wholesale, which has no
    /// history to back off from.
    public mutating func reset() {
        self = CutBackoff()
    }
}
