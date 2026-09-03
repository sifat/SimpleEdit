import AppKit

/// Builds the whole menu bar in code.
///
/// Marked @MainActor explicitly because NSMenu is NOT annotated NS_SWIFT_UI_ACTOR
/// in the SDK, unlike NSResponder / NSDocument / NSDocumentController -- so this
/// file would otherwise sit in a nonisolated context while wiring main-actor
/// targets.
@MainActor
enum MainMenu {

    static func build(appName: String, recentsDelegate: NSMenuDelegate) -> NSMenu {
        let root = NSMenu()
        root.addItem(submenu: applicationMenu(appName: appName))
        root.addItem(submenu: fileMenu(recentsDelegate: recentsDelegate))
        root.addItem(submenu: editMenu())
        root.addItem(submenu: formatMenu())
        root.addItem(submenu: viewMenu())
        root.addItem(submenu: windowMenu())
        return root
    }

    // MARK: - Application

    private static func applicationMenu(appName: String) -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.item(
            "About \(appName)",
            #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        )
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = menu.item("Services", nil)
        servicesItem.submenu = services
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        menu.item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
        menu.item(
            "Hide Others",
            #selector(NSApplication.hideOtherApplications(_:)),
            "h",
            [.command, .option]
        )
        menu.item("Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        menu.item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    // MARK: - File

    private static func fileMenu(recentsDelegate: NSMenuDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.item("New", #selector(NSDocumentController.newDocument(_:)), "n")
        menu.item("Open…", #selector(NSDocumentController.openDocument(_:)), "o")

        // AppKit's automatic population of this submenu in a code-built (no-xib)
        // menu bar is undocumented folklore, so we fill it ourselves from
        // NSDocumentController.recentDocumentURLs, which is plain public API.
        let recents = NSMenu(title: "Open Recent")
        recents.delegate = recentsDelegate
        menu.item("Open Recent", nil).submenu = recents

        menu.addItem(.separator())
        menu.item("Close", #selector(NSWindow.performClose(_:)), "w")
        menu.item("Save", #selector(NSDocument.save(_:)), "s")
        menu.item("Save As…", #selector(NSDocument.saveAs(_:)), "S")
        menu.item("Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
        return menu
    }

    // MARK: - Edit

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")

        // undo: and redo: are declared NOWHERE in AppKit -- a grep of every header
        // returns zero hits, because NSUndoManager services them through the
        // responder chain with no public declaration. #selector(...) is a compile
        // error here; untyped selectors are the only way to name them.
        menu.item("Undo", Selector(("undo:")), "z")
        menu.item("Redo", Selector(("redo:")), "Z")
        menu.addItem(.separator())

        menu.item("Cut", #selector(NSText.cut(_:)), "x")
        menu.item("Copy", #selector(NSText.copy(_:)), "c")
        menu.item("Paste", #selector(NSText.paste(_:)), "v")
        menu.item("Delete", #selector(NSText.delete(_:)))
        menu.item("Select All", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        menu.item("Find", nil).submenu = find

        // Every item targets First Responder and carries an NSTextFinder.Action
        // raw value as its tag; performTextFinderAction: dispatches on the
        // sender's tag, not on an argument. A concrete target would break the
        // moment there is more than one tab.
        find.finderItem("Find…", .showFindInterface, "f")
        find.finderItem("Find and Replace…", .showReplaceInterface, "f", [.command, .option])
        find.finderItem("Find Next", .nextMatch, "g")
        // Uppercase "G" with .command only: AppKit infers Shift from the capital,
        // which is exactly what TextEdit's own nib stores. Adding .shift as well
        // would render as a different, broken equivalent.
        find.finderItem("Find Previous", .previousMatch, "G")
        find.finderItem("Use Selection for Find", .setSearchString, "e")
        find.item(
            "Jump to Selection",
            #selector(NSResponder.centerSelectionInVisibleArea(_:)),
            "j"
        )
        return menu
    }

    // MARK: - Format

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.item(
            "Format JSON",
            #selector(EditorViewController.formatJSON(_:)),
            "j",
            [.command, .control]
        )
        menu.item(
            "Minify JSON",
            #selector(EditorViewController.minifyJSON(_:)),
            "J",
            [.command, .control]
        )
        menu.item("Validate JSON", #selector(EditorViewController.validateJSON(_:)))
        return menu
    }

    // MARK: - View

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.item(
            "Line Numbers",
            #selector(EditorViewController.toggleLineNumbers(_:)),
            "l",
            [.command, .control]
        )
        menu.item(
            "Wrap Lines",
            #selector(EditorViewController.toggleWrapsLines(_:)),
            "w",
            [.command, .option]
        )
        menu.addItem(.separator())
        // AppKit retitles this to "Exit Full Screen" by itself.
        menu.item(
            "Enter Full Screen",
            #selector(NSWindow.toggleFullScreen(_:)),
            "f",
            [.command, .control]
        )
        return menu
    }

    // MARK: - Window

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        menu.item("Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())

        // NSWindow already declares these as IBActions and precedes its window
        // controller in the responder chain -- so we point at NSWindow's own
        // selectors rather than defining our own, which would be intercepted and
        // validate to disabled. The system default is Ctrl-Tab; these add the
        // bracket shortcuts every other Mac editor has.
        menu.item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift])
        menu.item(
            "Show Previous Tab",
            #selector(NSWindow.selectPreviousTab(_:)),
            "[",
            [.command, .shift]
        )
        menu.addItem(.separator())
        menu.item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))

        NSApp.windowsMenu = menu  // lets AppKit inject its own tab commands
        return menu
    }
}

// MARK: - Menu-building conveniences

extension NSMenu {
    @discardableResult
    func item(
        _ title: String,
        _ action: Selector?,
        _ keyEquivalent: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        if !keyEquivalent.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        item.target = nil  // First Responder
        addItem(item)
        return item
    }

    @discardableResult
    func finderItem(
        _ title: String,
        _ action: NSTextFinder.Action,
        _ keyEquivalent: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = item(
            title,
            #selector(NSResponder.performTextFinderAction(_:)),
            keyEquivalent,
            modifiers
        )
        // Never hand-write these integers, and never use the legacy
        // NSFindPanelAction constants -- different underlying type, and no
        // counterparts for 11/12/13.
        item.tag = action.rawValue
        return item
    }

    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
