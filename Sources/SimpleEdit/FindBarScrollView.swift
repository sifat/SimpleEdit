import AppKit

/// An NSScrollView that hands first responder back to the text view when the
/// find bar closes.
///
/// AppKit never delivers NSTextFinder.Action.hideFindInterface when the user
/// presses Escape or clicks Done, and posts no notification either, so focus
/// would otherwise stay in the search field. The usual workaround is KVO on
/// `isFindBarVisible`, but that property is never redeclared on NSScrollView --
/// it arrives only as an NSTextFinderBarContainer requirement, so its KVO
/// compliance is unverified. Overriding the property NSScrollView actually
/// implements cannot silently fail the same way.
final class FindBarScrollView: NSScrollView {
    override var isFindBarVisible: Bool {
        didSet {
            guard oldValue, !isFindBarVisible else { return }
            if let textView = documentView as? NSTextView {
                window?.makeFirstResponder(textView)
            }
        }
    }
}
