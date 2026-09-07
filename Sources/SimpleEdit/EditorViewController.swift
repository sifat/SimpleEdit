import AppKit
import EditorCore

/// Owns the text view for one tab.
///
/// The editor actions live here rather than on the window controller because
/// NSViewController is an NSResponder and sits in the chain automatically, so
/// menu items targeting First Responder reach whichever tab is focused without
/// any per-tab bookkeeping.
final class EditorViewController: NSViewController, NSTextViewDelegate {

    private(set) var textView: NSTextView!
    private var scrollView: FindBarScrollView!
    private var ruler: LineNumberRulerView!

    private var didLoadDocumentText = false
    private(set) var wrapsLines = true
    private(set) var showsLineNumbers = true

    /// Wrapping one enormous line is far more expensive than scrolling it, and a
    /// minified JSON file is exactly one enormous line.
    private static let wrapDisableLineLength = 100_000

    /// The text view and scroll view are built before either is in a window, so
    /// they need a non-degenerate starting size; autoresizing takes over after the
    /// first layout pass.
    private static let initialFrame = NSRect(x: 0, y: 0, width: 900, height: 640)

    var document: TextDocument? {
        view.window?.windowController?.document as? TextDocument
    }

    // MARK: - View

    override func loadView() {
        // TextKit 2. Viewport-based layout is dramatically better on large and
        // single-line files, and it is safe here only because the built-in find
        // bar means we never need addTemporaryAttribute for highlight-all.
        // To fall back to TextKit 1: pass false here and switch the ruler to
        // NSLayoutManager.enumerateLineFragments.
        let textView = NSTextView(usingTextLayoutManager: true)
        // NSTextView.h is explicit that this initialiser "is initialized with frame
        // NSZeroRect". Without a real frame the text view is 0x0: present in the
        // hierarchy and hit-testable by nothing, so the window looks fine and
        // simply cannot be typed into.
        textView.frame = NSRect(origin: .zero, size: Self.initialFrame.size)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 6)

        textView.isRichText = false
        textView.allowsUndo = true  // defaults to NO; undo does nothing without this
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindPanel = true  // gates the find machinery
        textView.usesFindBar = true  // bar rather than the old panel
        textView.isIncrementalSearchingEnabled = true  // dims everything but the matches
        textView.delegate = self

        let scrollView = FindBarScrollView(frame: Self.initialFrame)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.findBarPosition = .aboveContent
        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        self.textView = textView
        self.scrollView = scrollView
        self.ruler = ruler

        applyWrapping()
        view = scrollView

    }

    override func viewWillAppear() {
        super.viewWillAppear()
        loadDocumentTextIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Otherwise the window opens with first responder unset and the first
        // keystroke goes nowhere.
        view.window?.makeFirstResponder(textView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // loadView() ran before the scroll view had a real size, so the wrapping
        // width computed there was based on a zero content size.
        guard wrapsLines, let container = textView.textContainer else { return }
        container.size = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func loadDocumentTextIfNeeded() {
        guard !didLoadDocumentText, let document else { return }
        didLoadDocumentText = true
        applyDocumentText(document.text)
    }

    /// Pulls the document's text into the view again, discarding what is on
    /// screen.
    ///
    /// Revert to Saved needs this. NSDocument's revert replaces the document's
    /// storage and has no idea a view is showing the old text, and
    /// loadDocumentTextIfNeeded refuses to run twice -- so before this existed
    /// the view kept the stale text, and because data(ofType:) commits
    /// textView.string on the way out, the next save wrote that stale text
    /// straight back over the file the user had just reverted.
    func reloadDocumentText() {
        guard let document else { return }
        didLoadDocumentText = true
        applyDocumentText(document.text)
    }

    private func applyDocumentText(_ text: String) {
        // Assigning `string` directly does not post NSText.didChangeNotification
        // and registers no undo, so opening a file does not mark it edited.
        textView.string = text

        let longest = TextMetrics.longestLineLength(
            in: textView.string,
            stoppingAbove: Self.wrapDisableLineLength
        )
        if longest > Self.wrapDisableLineLength {
            wrapsLines = false
            applyWrapping()
        }
        documentTextDidArrive()
    }

    /// Everything that has to happen when the whole text changes at once rather
    /// than through editing. One place, because assigning `string` posts no
    /// notification, so each of these consumers has to be told by hand and it is
    /// easy to add a third and forget one.
    private func documentTextDidArrive() {
        ruler.documentDidLoad()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        document?.updateChangeCount(.changeDone)
    }

    /// Nothing wires a text view to its document's undo manager: NSWindowController
    /// does not implement windowWillReturnUndoManager:. Routing through the
    /// document's manager is what makes undo per-tab.
    func undoManager(for view: NSTextView) -> UndoManager? {
        document?.undoManager
    }

    // MARK: - Document hand-off

    /// Pulls the current text back into the document. Called on the save path
    /// rather than on every keystroke, so typing does not copy the whole string.
    ///
    /// `breakingUndoCoalescing` is false for autosave. Closing the typing undo
    /// group is right at a boundary the user chose and wrong on a timer, where
    /// it would chop undo history at arbitrary wall-clock moments.
    func commitTextToDocument(breakingUndoCoalescing: Bool = true) {
        if breakingUndoCoalescing {
            textView.breakUndoCoalescing()
        }
        document?.text = textView.string
    }

    // MARK: - JSON actions

    @objc func formatJSON(_ sender: Any?) { runJSON(.pretty) }
    @objc func minifyJSON(_ sender: Any?) { runJSON(.minify) }
    @objc func validateJSON(_ sender: Any?) { runJSON(.validate) }

    private static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    private func runJSON(_ mode: JSONMode) {
        // Work in bytes. The helper wants UTF-8 anyway, and slicing a BOM off
        // Data costs nothing where dropping a Character off a String copied the
        // whole document.
        let source = Data(textView.string.utf8)

        // Go's scanner treats a BOM as an invalid character rather than
        // whitespace, so strip it here and put it back on the way out.
        let hadBOM = source.starts(with: Self.utf8BOM)
        let body = hadBOM ? source.dropFirst(Self.utf8BOM.count) : source

        // Byte-level whitespace rather than trimmingCharacters, which allocated
        // a second full copy of the document purely to test it for emptiness.
        // A document of only non-ASCII whitespace now reaches the helper and
        // comes back as a syntax error rather than "nothing to format", which
        // is the more accurate of the two answers.
        guard !body.allSatisfy(\.isJSONWhitespace) else {
            presentMessage("Nothing to format", detail: "This document is empty.")
            return
        }

        do {
            let result = try JSONTool.run(mode, on: body)
            if mode == .validate {
                presentMessage("Valid JSON", detail: "The document parses cleanly.", style: .informational)
                return
            }
            replaceEntireDocument(with: hadBOM ? "\u{FEFF}" + result : result)
        } catch let error as JSONToolError {
            // Decode back to a String only here. The offset mapping needs one,
            // and this is the rare path.
            present(error, in: String(decoding: body, as: UTF8.self), bomOffset: hadBOM ? 1 : 0)
        } catch {
            presentMessage("Could not run the JSON helper", detail: error.localizedDescription)
        }
    }

    /// One edit, not many: otherwise Format costs a multi-step undo and repeated
    /// relayout of the whole document.
    private func replaceEntireDocument(with newText: String) {
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: whole, replacementString: newText) else { return }

        textView.breakUndoCoalescing()
        storage.beginEditing()
        storage.replaceCharacters(in: whole, with: newText)
        storage.endEditing()
        textView.didChangeText()

        documentTextDidArrive()
    }

    private func present(_ error: JSONToolError, in body: String, bomOffset: Int) {
        guard let byteOffset = error.byteOffset else {
            presentMessage("Invalid JSON", detail: error.message)
            return
        }

        let location = SourceLocationMapper.locate(byteOffset: byteOffset, in: body)
        let caret = location.utf16Offset + bomOffset
        let length = (textView.string as NSString).length

        if caret <= length {
            let range = NSRange(location: caret, length: min(1, length - caret))
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }

        presentMessage(
            "Invalid JSON",
            detail: "Line \(location.line), column \(location.column): \(error.message)"
        )
    }

    private func presentMessage(
        _ title: String,
        detail: String,
        style: NSAlert.Style = .warning
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - View options

    @objc func toggleWrapsLines(_ sender: Any?) {
        wrapsLines.toggle()
        applyWrapping()
    }

    @objc func toggleLineNumbers(_ sender: Any?) {
        showsLineNumbers.toggle()
        scrollView.rulersVisible = showsLineNumbers
    }

    private func applyWrapping() {
        guard let container = textView.textContainer else { return }
        if wrapsLines {
            container.widthTracksTextView = true
            container.size = NSSize(
                width: scrollView.contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width, .height]
            scrollView.hasHorizontalScroller = true
        }
        textView.needsDisplay = true
    }

}

// MARK: - Menu validation

extension EditorViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleWrapsLines(_:)):
            menuItem.state = wrapsLines ? .on : .off
        case #selector(toggleLineNumbers(_:)):
            menuItem.state = showsLineNumbers ? .on : .off
        default:
            break
        }
        return true
    }
}
