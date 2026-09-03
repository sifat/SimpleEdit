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

    override func data(ofType typeName: String) throws -> Data {
        if let editor = windowControllers.first?.contentViewController as? EditorViewController {
            editor.commitTextToDocument()
        }
        return TextFileIO.encode(storage.decoded)
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
