import AppKit

// The entry point lives in AppMain.swift -- see the comment there for why @main
// on this class is not enough. No file here may be named main.swift either:
// SwiftPM treats that filename as top-level code, which collides with @main.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The first NSDocumentController instantiated becomes `.shared`, so this
    /// must be a stored property rather than something created later.
    private let documentController = EditorDocumentController()

    private let recentDocuments = RecentDocumentsMenuDelegate()

    private static let restoreKey = "OpenDocumentPaths"
    private var pendingRestore: [URL] = []

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "SimpleEdit"
    }

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // JSONTool writes to a child process's stdin. If that child ever exits
        // early, an unguarded write raises SIGPIPE and kills the app.
        signal(SIGPIPE, SIG_IGN)

        // The menu bar must exist before AppKit's launch-time checks run.
        NSApp.mainMenu = MainMenu.build(appName: appName, recentsDelegate: recentDocuments)

        pendingRestore = (UserDefaults.standard.array(forKey: Self.restoreKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        reopenPendingDocuments()
    }

    /// Suppress the automatic blank document when we are about to restore tabs.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        pendingRestore.isEmpty
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Tabs

    /// The + button in the tab bar does not appear unless this exists somewhere
    /// in the responder chain. NSDocumentController does not implement it, and
    /// the selector appears exactly once in all of AppKit, in NSResponder.h.
    @objc func newWindowForTab(_ sender: Any?) {
        documentController.newDocument(sender)
    }

    // MARK: - Session restore

    /// Reopening is done explicitly rather than via macOS Resume so that it works
    /// regardless of the user's "Close windows when quitting an application"
    /// setting. Unsaved untitled tabs have no URL and do not come back.
    private func reopenPendingDocuments() {
        let urls = pendingRestore
        pendingRestore = []
        for url in urls {
            documentController.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let paths = documentController.documents.compactMap { $0.fileURL?.path }
        UserDefaults.standard.set(paths, forKey: Self.restoreKey)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Fills File ▸ Open Recent from public API each time it opens.
final class RecentDocumentsMenuDelegate: NSObject, NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let urls = NSDocumentController.shared.recentDocumentURLs
        guard !urls.isEmpty else {
            let empty = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for url in urls {
            let item = NSMenuItem(
                title: url.lastPathComponent,
                action: #selector(open(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clear(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    @objc private func clear(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }
}
