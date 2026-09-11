import AppKit
import EditorCore

/// One open file.
///
/// The @objc name is load-bearing: Info.plist resolves NSDocumentClass by string
/// at runtime with no compile-time check, and a Swift class otherwise registers
/// as Module.Class. Dropping this attribute reintroduces a runtime-only
/// "the document could not be opened" with zero build signal.
@objc(TextDocument)
final class TextDocument: NSDocument {

    /// read(from:ofType:) is imported nonisolated while data(ofType:) is
    /// @MainActor, so the model cannot be main-actor state. A lock-guarded box
    /// keeps both paths honest.
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var value = DecodedText()

        var decoded: DecodedText {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }

        var text: String {
            get { lock.withLock { value.text } }
            set { lock.withLock { value.text = newValue } }
        }
    }

    private let storage = Storage()

    var text: String {
        get { storage.text }
        set { storage.text = newValue }
    }

    var lineEndingName: String { storage.decoded.lineEnding.displayName }

    // Autosave stays off. With it on, AppKit rewrites the user's real file as
    // they type -- including source files and dotfiles opened by accident -- and
    // suppresses the save-changes alert on close.
    override nonisolated class var autosavesInPlace: Bool { false }

    // MARK: - Windows

    override func makeWindowControllers() {
        addWindowController(EditorWindowController())
    }

    // MARK: - Reading and writing

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        storage.decoded = TextFileIO.decode(data)
    }

    /// Which kind of save is in flight, so `data(ofType:)` can tell an explicit
    /// save from a timer.
    ///
    /// NSDocument.h says to do exactly this rather than consulting
    /// +autosavesInPlace: "You should instead use the NSSaveOperationType
    /// parameter passed to your overrides of -save... and -write... methods."
    private var currentSaveOperation: NSDocument.SaveOperationType?

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        currentSaveOperation = saveOperation
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            self?.currentSaveOperation = nil
            completionHandler(error)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        if let editor = windowControllers.first?.contentViewController as? EditorViewController {
            // Breaking undo coalescing is right at a save the user asked for and
            // wrong on a timer. Autosave fires mid-typing, so doing it there
            // closes the typing undo group at an arbitrary wall-clock moment:
            // the next Undo then reverts back to whenever the timer happened to
            // fire rather than to the last word.
            let isAutosave = currentSaveOperation?.isAutosave ?? false
            editor.commitTextToDocument(breakingUndoCoalescing: !isAutosave)
        }
        return TextFileIO.encode(storage.decoded)
    }

    /// NSDocument's revert replaces this document's storage but knows nothing
    /// about the view showing the old text, and the editor deliberately loads
    /// its text only once. Without this override the view kept the stale text --
    /// and since data(ofType:) commits textView.string on the way out, the next
    /// save wrote that stale text straight back over the file the user had just
    /// reverted. Reproduced: revert, then Cmd-S, and the edit reappeared on disk.
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        if let editor = windowControllers.first?.contentViewController as? EditorViewController {
            editor.reloadDocumentText()
        }
    }

    // MARK: - Printing

    /// Prints a throwaway text view built for the paper, never the one on screen.
    ///
    /// The on-screen view is sized to the window, carries the line-number ruler,
    /// and when wrapping is off has a container of effectively infinite width --
    /// printing it yields a single absurdly wide page.
    ///
    /// The print view is TextKit **1** on purpose. Pagination goes through
    /// knowsPageRange:/rectForPage:, which the layout manager drives; that path is
    /// decades old under TextKit 1, while TextKit 2 is built around laying out
    /// only the visible viewport -- the opposite of what paginating a whole
    /// document needs. This view is ephemeral and never enters a window, so the
    /// app stays TextKit 2 on screen and never has to find out whether TextKit 2
    /// pagination works. Reading `layoutManager` here is safe for the same
    /// reason it is forbidden elsewhere: this view really is TextKit 1, so there
    /// is no TextKit 2 instance to silently downgrade.
    override func printOperation(
        withSettings printSettings: [NSPrintInfo.AttributeKey: Any]
    ) throws -> NSPrintOperation {
        if let editor = windowControllers.first?.contentViewController as? EditorViewController {
            editor.commitTextToDocument()
        }

        let attributes = (printInfo.dictionary() as? [NSPrintInfo.AttributeKey: Any]) ?? [:]
        let info = NSPrintInfo(dictionary: attributes.merging(printSettings) { _, new in new })

        let contentWidth = max(1, info.paperSize.width - info.leftMargin - info.rightMargin)

        let printView = NSTextView(usingTextLayoutManager: false)
        printView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentWidth)
        printView.isRichText = false
        printView.isEditable = false
        printView.textContainerInset = .zero
        // 10pt, not the editor's 13pt. A US Letter page minus default margins is
        // 468pt wide, which fits about 78 monospaced columns at 10pt and only
        // about 60 at 13pt -- so matching the screen size would wrap ordinary
        // 80-column code that has no business wrapping on paper.
        printView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        printView.isHorizontallyResizable = false
        printView.isVerticallyResizable = true
        printView.maxSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        printView.textContainer?.containerSize = NSSize(
            width: contentWidth,
            height: .greatestFiniteMagnitude
        )
        printView.textContainer?.widthTracksTextView = true
        printView.string = storage.text

        // Lay out before measuring, or sizeToFit sees an empty view and every
        // page after the first comes out blank.
        if let container = printView.textContainer {
            printView.layoutManager?.ensureLayout(for: container)
        }
        printView.sizeToFit()

        let operation = NSPrintOperation(view: printView, printInfo: info)
        operation.jobTitle = displayName
        return operation
    }

    // MARK: - Save panel

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        // An empty content-type list means "any type" and hides the file-format
        // popup, which is what a plain-text editor wants. allowedFileTypes:
        // ([String]) is deprecated since macOS 12; this is the [UTType] door.
        savePanel.allowedContentTypes = []
        savePanel.allowsOtherFileTypes = true
        savePanel.isExtensionHidden = false
        return true
    }
}

extension NSDocument.SaveOperationType {
    /// True for the three operations AppKit drives itself rather than the user.
    ///
    /// `.autosaveOperation` is the deprecated spelling of
    /// `.autosaveElsewhereOperation` and shares its raw value, so naming it here
    /// as well would be a duplicate case rather than extra coverage.
    var isAutosave: Bool {
        switch self {
        case .autosaveElsewhereOperation, .autosaveInPlaceOperation, .autosaveAsOperation:
            true
        default:
            false
        }
    }
}
