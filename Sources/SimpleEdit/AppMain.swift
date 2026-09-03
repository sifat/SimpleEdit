import AppKit

/// Explicit entry point.
///
/// @main on an NSApplicationDelegate compiles and launches -- AppKit's
/// swiftinterface supplies `static func main() { exit(NSApplicationMain(...)) }`
/// -- but NSApplicationMain only ever *discovers* a delegate by loading the main
/// nib. With no nib and no NSMainNibFile there is nothing to load, so NSApp.delegate
/// stays nil: no menu bar, no untitled document, no window, just a live run loop.
/// The app looks like it started and does nothing at all.
///
/// So we build the application object ourselves.
@main
enum SimpleEditMain {

    /// NSApplication.delegate is a weak reference, so ownership has to live here
    /// or the delegate deallocates the moment main() returns from assigning it.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}
