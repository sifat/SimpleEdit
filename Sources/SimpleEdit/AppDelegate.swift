import AppKit

// The entry point lives in AppMain.swift -- see the comment there for why @main
// on this class is not enough. No file here may be named main.swift either:
// SwiftPM treats that filename as top-level code, which collides with @main.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The first NSDocumentController instantiated becomes `.shared`, so this
    /// must be a stored property rather than something created later.
    private let documentController = EditorDocumentController()

    private let recentDocuments = RecentDocumentsMenuDelegate()

    private static let appearanceKey = "Appearance"
    private static let restoreKey = "OpenDocumentPaths"
    private var pendingRestore: [URL] = []
    private var didFinishLaunching = false
    private var didFinishRestoring = false

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "SimpleEdit"
    }

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // JSONTool writes to a child process's stdin. If that child ever exits
        // early, an unguarded write raises SIGPIPE and kills the app.
        signal(SIGPIPE, SIG_IGN)

        // Before any window exists, so a forced Light or Dark never shows as a
        // flash of the system appearance at launch.
        applyAppearance(appearanceSetting)

        // The menu bar must exist before AppKit's launch-time checks run.
        NSApp.mainMenu = MainMenu.build(appName: appName, recentsDelegate: recentDocuments)

        // Periodic autosave defaults to OFF: NSDocumentController.autosavingDelay
        // is documented as "a value of 0 indicates that periodic autosaving
        // should not be done at all", and 0 is the default.
        //
        // This is the pre-10.7 crash-protection path, not autosave-in-place.
        // Because TextDocument.autosavesInPlace stays false, AppKit uses
        // NSAutosaveElsewhereOperation -- "writing of a document's current
        // contents to a file or file package that is separate from the
        // document's current one, without changing the document's current one".
        // The user's actual file is still only written when they ask for it.
        //
        // 30s rather than something tighter because writing happens on the main
        // thread: data(ofType:) reaches into the view, so this cannot be made
        // asynchronous without crashing.
        documentController.autosavingDelay = 30

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowRestorationDidFinish),
            name: NSApplication.didFinishRestoringWindowsNotification,
            object: nil
        )

        pendingRestore = (UserDefaults.standard.array(forKey: Self.restoreKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        didFinishLaunching = true
        restoreSessionIfReady()
    }

    /// Our restore has to wait for AppKit's to finish, or the already-open check
    /// below sees nothing and reopens files AppKit is about to restore anyway.
    ///
    /// NSWindowRestoration.h is explicit that this notification "may be posted
    /// before or after NSApplicationDidFinishLaunching", so neither event can be
    /// assumed to arrive second; whichever is last does the work. It is always
    /// posted, even when there was nothing to restore, so the pending list
    /// cannot be stranded.
    @objc private func windowRestorationDidFinish() {
        didFinishRestoring = true
        restoreSessionIfReady()
    }

    private func restoreSessionIfReady() {
        guard didFinishLaunching, didFinishRestoring else { return }
        reopenPendingDocuments()
        closeDuplicateDocuments()
    }

    /// Suppress the automatic blank document when we are about to restore tabs.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        pendingRestore.isEmpty
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Appearance

    /// An absent key means System, deliberately, rather than registering a
    /// default: a fresh install then behaves exactly as it did before this
    /// preference existed.
    private var appearanceSetting: AppearanceSetting {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.appearanceKey),
                  let setting = AppearanceSetting(rawValue: raw)
            else { return .system }
            return setting
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.appearanceKey)
            applyAppearance(newValue)
        }
    }

    /// Setting it on NSApp is enough for every window, including tabs and
    /// windows opened later: effectiveAppearance resolves view -> window ->
    /// application at draw time, and nothing in this app sets `appearance` on a
    /// window of its own, so they all inherit.
    private func applyAppearance(_ setting: AppearanceSetting) {
        NSApp.appearance = setting.appearance
    }

    @objc func changeAppearance(_ sender: NSMenuItem) {
        guard let setting = AppearanceSetting(tag: sender.tag) else { return }
        appearanceSetting = setting
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
            // Skip anything AppKit already put on screen, or the same file gets
            // a second tab.
            guard documentController.document(for: url) == nil else { continue }
            documentController.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    /// Collapses two tabs showing the same file down to one.
    ///
    /// Turning autosave on made AppKit open some documents twice after a crash:
    /// once from saved window state and once from the autosave record. Measured
    /// -- by the time NSApplicationDidFinishRestoringWindows arrives, the
    /// duplicate is already there, before any of our own restore code runs, so
    /// this cannot be fixed by reordering or by skipping on our side.
    ///
    /// Keep whichever copy carries unsaved work. If both do, keep both: two tabs
    /// is a confusing outcome, but silently closing someone's unsaved edit to
    /// tidy the window is a much worse one. `close()` discards without asking,
    /// so it is only ever reached for a document with nothing to lose.
    private func closeDuplicateDocuments() {
        var keptByURL: [URL: NSDocument] = [:]

        for document in documentController.documents {
            guard let url = document.fileURL?.standardizedFileURL else { continue }
            guard let incumbent = keptByURL[url] else {
                keptByURL[url] = document
                continue
            }

            if !document.isDocumentEdited {
                document.close()
            } else if !incumbent.isDocumentEdited {
                keptByURL[url] = document
                incumbent.close()
            }
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

extension AppDelegate: NSMenuItemValidation {
    /// The Appearance items target First Responder and nothing before the app
    /// delegate implements changeAppearance:, so validation lands here and can
    /// put the checkmark on the active one.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(changeAppearance(_:)) {
            menuItem.state = menuItem.tag == appearanceSetting.tag ? .on : .off
        }
        return true
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
