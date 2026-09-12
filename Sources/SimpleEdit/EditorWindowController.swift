import AppKit

/// One window per document. AppKit merges these into a single tabbed window.
///
/// Sharing one window controller across tabs is a known-broken pattern: closing
/// the root window nils out `tabbedWindows`, key/main status diverges between
/// programmatic and manual tab selection, and frames snap when a key tab closes.
final class EditorWindowController: NSWindowController {

    /// Windows only tab together when they share this.
    static let tabbingIdentifier = "com.sifat.simpleedit.document"

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Must be set before the window is first shown. .preferred deliberately
        // overrides System Settings, including an explicit "Prefer tabs: Never" --
        // the spec asks for tabs, so tabs it is.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.isRestorable = true
        window.minSize = NSSize(width: 420, height: 260)

        // A window built in code does not advertise full-screen support on its
        // own: without .fullScreenPrimary the green button only zooms and
        // View > Enter Full Screen stays disabled.
        window.collectionBehavior.insert(.fullScreenPrimary)

        // Zoom (the green button, and double-clicking the title bar when the
        // system is set to "zoom") needs a maximum size that is not the default
        // content size, or the window has nothing to grow into.
        window.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        self.init(window: window)
        window.delegate = self
        // Tabs are one window; cascading fights the tab group.
        shouldCascadeWindows = false
        contentViewController = EditorViewController()

        // Order matters. Assigning contentViewController makes AppKit resize the
        // window to the view controller's fitting size, and a bare NSScrollView
        // has no intrinsic content size -- so the window collapses to minSize.
        // Size it AFTER the content view controller is in place.
        window.setContentSize(Self.defaultContentSize)
        place(window)

    }

    static let defaultContentSize = NSSize(width: 900, height: 640)

    /// NSWindow.center() put the window on the secondary display on a two-monitor
    /// setup, which is indistinguishable from "the app opened nothing". Place it
    /// on the active screen explicitly.
    private func place(_ window: NSWindow) {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        window.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        )
    }
}

extension EditorWindowController: NSWindowDelegate {

    /// Makes zoom fill the screen.
    ///
    /// Double-clicking the title bar sends `zoom:` (when System Settings ▸ Desktop
    /// & Dock ▸ "Double-click a window's title bar to" is set to Zoom, the
    /// default), and so does the green button. AppKit's default standard frame is
    /// derived from the content view's preferred size, which for a text view that
    /// has no intrinsic size is roughly the current size -- so zoom appears to do
    /// nothing. Filling the visible frame is what people expect from an editor.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? defaultFrame
    }
}
