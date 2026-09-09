import AppKit
import SyntaxCore

/// Colours one document's text view. One per tab.
///
/// The only file in the app that touches NSTextLayoutManager, and the only one
/// that would change if the delivery mechanism ever had to move.
///
/// Colour is applied through rendering attributes, never by mutating
/// NSTextStorage, so it cannot reach undo, the edited flag or the save path.
/// Verified: a highlighted document saves byte-identical.
final class SyntaxHighlighter: NSObject, NSTextStorageDelegate {

    private weak var textView: NSTextView?
    private let parser: SyntaxParser
    private let language: SyntaxLanguage
    private var tokens: SyntaxTokenList = .empty

    /// Two limits protect the keystroke path, and they do different jobs.
    ///
    /// `SyntaxLanguage.maximumLength` is a size cap: above it nothing is
    /// attempted. It bounds the ordinary cost of an ordinary file.
    ///
    /// `SyntaxParser.defaultBudget` is a time budget: parsing and querying stop
    /// at ~80 ms and the document is left plain. It bounds the worst case,
    /// which a size cap cannot -- the worst case is nesting depth and
    /// unbalanced brackets, quadratic, and reachable from a normal file
    /// halfway through being typed. See the comments on both for the
    /// measurements.
    ///
    /// Almost none of the cost is tree-sitter's own parsing on ordinary input;
    /// it was the Swift binding's per-capture allocation, which is why the
    /// parser drives the C API directly.
    init?(language: SyntaxLanguage, textView: NSTextView) {
        guard let queriesRoot = Bundle.main.resourceURL?
            .appendingPathComponent("Queries", isDirectory: true)
        else { return nil }

        // Fails soft. A missing or broken query file leaves the document plain
        // rather than crashing: the file lives inside the app bundle, so this
        // is a packaging mistake, and a packaging mistake should not be fatal
        // to opening a document.
        guard let parser = SyntaxParser(language: language, queriesRoot: queriesRoot) else {
            NSLog("SimpleEdit: no syntax parser for \(language.rawValue); leaving the document plain")
            return nil
        }

        self.parser = parser
        self.language = language
        self.textView = textView
        super.init()
        installValidator()

        // Every change to the text, however it is made -- typing, paste, undo,
        // Replace All, `textView.string = ...` -- goes through NSTextStorage,
        // and didProcessEditing reports what ACTUALLY changed, after the fact.
        // That is the property the incremental parse depends on: the tree is
        // edited to match the text exactly as it is, never as an edit was
        // intended to be.
        textView.textStorage?.delegate = self
    }

    // MARK: - NSTextStorageDelegate

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // Attribute-only edits (the find bar's dimming, typing attributes)
        // change no text and must not be reported as if they had.
        guard editedMask.contains(.editedCharacters) else { return }
        // editedRange is in the NEW text; the old text ended `delta` earlier.
        parser.noteEdit(SyntaxParser.TextEdit(
            start: editedRange.location,
            oldEnd: NSMaxRange(editedRange) - delta,
            newEnd: NSMaxRange(editedRange)
        ))
    }

    // MARK: - Delivery

    private func installValidator() {
        guard let layoutManager = textView?.textLayoutManager else { return }

        // The pull path. TextKit 2 asks us for a fragment's colours as it lays
        // that fragment out, which is why this works where the push path does
        // not: it never needs an invalidation call to schedule a repaint.
        //
        // Two rules, both learned the hard way and both load-bearing:
        //
        // 1. NEVER call invalidateRenderingAttributes. The header's "enumerating
        //    rendering attributes will skip the invalidated range" is literal --
        //    it discards colour and never asks for it back, so the text goes
        //    black permanently, surviving edits and even a window resize. It is
        //    almost certainly what the public bug reports about this API are
        //    actually hitting.
        // 2. This block runs on the main thread inside layout, so it must stay a
        //    pure lookup. No parsing, no ensureLayout, no needsDisplay, no
        //    reading textView.string, nothing that could re-enter layout.
        layoutManager.renderingAttributesValidator = { [weak self] manager, fragment in
            guard let self, !self.tokens.isEmpty,
                  let contentManager = manager.textContentManager
            else { return }

            // rangeInElement is document-relative. NSTextLineFragment
            // .characterRange is NOT -- it is paragraph-relative, and using it
            // here would mis-colour every paragraph but the first.
            let fragmentRange = fragment.rangeInElement
            let start = contentManager.offset(
                from: contentManager.documentRange.location,
                to: fragmentRange.location
            )
            let length = contentManager.offset(
                from: fragmentRange.location,
                to: fragmentRange.endLocation
            )
            guard start != NSNotFound, length != NSNotFound, length > 0 else { return }

            for token in self.tokens.tokens(in: NSRange(location: start, length: length)) {
                let clipped = NSIntersectionRange(
                    token.range,
                    NSRange(location: start, length: length)
                )
                guard clipped.length > 0,
                      // Offset from the fragment's own start rather than the
                      // document's, so the walk is short whatever the cost of
                      // location(_:offsetBy:) turns out to be.
                      let from = contentManager.location(
                          fragmentRange.location,
                          offsetBy: clipped.location - start
                      ),
                      let to = contentManager.location(from, offsetBy: clipped.length),
                      let textRange = NSTextRange(location: from, end: to)
                else { continue }

                manager.addRenderingAttribute(
                    .foregroundColor,
                    value: SyntaxTheme.color(for: token.kind),
                    for: textRange
                )
            }
        }
    }

    // MARK: - Parsing

    /// Whole text arrived at once -- opened, reverted, or replaced by Format JSON.
    ///
    /// The text storage delegate has already reported the replacement as one
    /// edit, so reusing the tree would be correct; but a wholesale replacement
    /// shares nothing with what came before, and a fresh parse is the honest
    /// cost.
    func documentTextDidArrive() {
        parser.invalidate()
        reparse()
    }

    /// Parsed synchronously, on purpose.
    ///
    /// A debounced parse would finish *after* the layout pass the edit
    /// triggered, leaving the validator to colour with stale tokens; and there
    /// is no reliable way to repaint colour when the text itself has not
    /// changed, so the stale colours would simply persist. Parsing here means
    /// the tokens are already correct by the time TextKit asks for them.
    ///
    /// It is incremental: the parser has been told about every edit since the
    /// last parse (see the text storage delegate above) and re-lexes only
    /// around them. The highlights query still walks the whole tree, so the
    /// cost of a keystroke is now the query rather than the parse; the time
    /// budget bounds both.
    func textDidChange() {
        reparse()
    }

    private func reparse() {
        guard let textView else { return }
        let source = textView.string
        guard (source as NSString).length <= language.maximumLength else {
            tokens = .empty
            parser.invalidate()
            return
        }
        tokens = parser.tokens(for: source)
    }
}
