import AppKit
import EditorCore

/// A line-number gutter driven by TextKit 2 layout fragments.
///
/// Each NSTextLayoutFragment corresponds to one logical line (a paragraph), which
/// may wrap onto several visual lines, so drawing one number per fragment gives
/// the numbering people expect: wrapped continuations are not numbered.
final class LineNumberRulerView: NSRulerView {

    private weak var textView: NSTextView?

    /// Above this size the gutter goes blank rather than making typing lurch.
    ///
    /// Compared against UTF-16 code units, which is what LineIndex counts. The
    /// v1.0 name said "bytes" and was wrong by up to a factor of 3.
    ///
    /// 8 MB was the v1.0 value, chosen when the scan ran on every keystroke and
    /// made one Foundation call per line. Both of those are gone: the index is
    /// rebuilt at most once per frame and only after an edit, and the scan is a
    /// single pass over utf16. Measured on a 13.9 MB, 400k-line file, the new
    /// scan takes 43 ms against the old one's 161 ms -- so the old ceiling was
    /// four times too cautious for code that got four times faster.
    ///
    /// 64 MB is a guard against wedging the UI, not a considered editing limit;
    /// NSTextView itself is unpleasant well before it. Scrolling and reading
    /// cost nothing at any size, because a fresh index is never rebuilt. Typing
    /// into a file this large still costs one rescan per frame, which is the
    /// thing an incremental index would fix if it ever becomes worth doing.
    private static let maximumDocumentLength = 64 * 1024 * 1024

    private var lineIndex = LineIndexCache(maximumLength: maximumDocumentLength)

    /// Set while a thickness change is waiting for the next runloop turn, so a
    /// run of draws cannot queue the same resize repeatedly.
    private var thicknessUpdateScheduled = false

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let horizontalPadding: CGFloat = 6

    /// The drawn width of an n-digit number, measured once per digit count.
    ///
    /// The font is monospaced-digit, so every n-digit label is the same width
    /// and one measurement per n is exact. Measuring each label as it was drawn
    /// was a Core Text layout per visible line per frame -- the draw pass runs
    /// on every scroll event -- and the gutter-width check did the same again
    /// on every draw. At most ten entries; never invalidated, since the font
    /// is fixed for the life of the view.
    private var labelWidthByDigitCount: [Int: CGFloat] = [:]

    private func labelWidth(digits: Int) -> CGFloat {
        if let width = labelWidthByDigitCount[digits] { return width }
        let sample = String(repeating: "8", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: font]).width
        labelWidthByDigitCount[digits] = width
        return width
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(textDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )

        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(
            self,
            selector: #selector(viewportDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Invalidate only -- never rebuild here.
    ///
    /// The rebuild happens at the next draw, which runs at most once per frame
    /// however fast someone types. v1.0 claimed exactly this and then rebuilt
    /// synchronously on the next line, so every single keystroke paid a full
    /// document bridge, scan and allocation.
    @objc private func textDidChange() {
        lineIndex.invalidate()
        needsDisplay = true
    }

    @objc private func viewportDidChange() {
        needsDisplay = true
    }

    /// Call after loading a document, since a programmatic `string` assignment
    /// does not post NSText.didChangeNotification.
    func documentDidLoad() {
        lineIndex.invalidate()
        // Size the gutter up front rather than leaving it to the next draw, so
        // the text is not laid out against a width that is about to change.
        // Safe to do synchronously: this is not a draw pass.
        if let textView, let index = lineIndex.index(for: textView.string) {
            applyThickness(thickness(forHighestLine: index.lineCount))
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Clip to our own bounds before filling. NSRulerView hands this method a
        // rect that is NOT clipped to the ruler -- measured at 900pt wide against
        // a 24.8pt ruler -- so filling `rect` directly paints an opaque rectangle
        // straight over the document and the text silently disappears.
        let gutter = rect.intersection(bounds)
        guard !gutter.isEmpty else { return }

        NSColor.controlBackgroundColor.setFill()
        gutter.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: gutter.minY, width: 1, height: gutter.height).fill()

        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange
        else { return }

        // Rebuilds at most once per frame, and only if an edit invalidated it.
        // The autoclosure matters here: with a fresh index, `textView.string` is
        // never evaluated, so scrolling does not copy the whole document per frame.
        //
        // nil means the document is too large to index. Draw the empty gutter and
        // stop. v1.0 fell back to a one-entry index instead, which is a perfectly
        // valid index meaning "one line" -- so every visible row was labelled "1".
        guard let index = lineIndex.index(for: textView.string) else { return }

        scheduleThicknessUpdateIfNeeded(for: index)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // An empty document has no text layout fragment at all -- TextKit 2 lays
        // out nothing when there is nothing to lay out -- so the enumeration
        // below never runs a single time and the caret sits on an unnumbered
        // line 1 until the first keystroke. Draw that line directly.
        //
        // Asked through documentRange rather than textView.string because
        // reading `string` copies the whole document, which is exactly what the
        // index cache's autoclosure exists to avoid on every frame.
        if contentManager.documentRange.isEmpty {
            draw(lineNumber: 1, atFragmentTop: 0, in: textView, attributes: attributes)
            return
        }

        // Deliberately NOT .ensuresLayout. Forcing TextKit 2 to lay out from inside
        // the ruler's draw pass re-enters the layout system while the text view is
        // mid-draw, and the text then never paints. Only ever read fragments the
        // viewport has already laid out.
        var trailingLineTop: CGFloat?
        var reachedDocumentEnd = false

        layoutManager.enumerateTextLayoutFragments(
            from: viewport.location,
            options: []
        ) { fragment in
            let origin = fragment.rangeInElement.location
            guard origin.compare(viewport.endLocation) != .orderedDescending else { return false }

            let offset = contentManager.offset(from: contentManager.documentRange.location, to: origin)
            let number = index.lineNumber(containing: offset)

            draw(
                lineNumber: number,
                atFragmentTop: fragment.layoutFragmentFrame.minY,
                in: textView,
                attributes: attributes
            )

            // Where the empty final line would sit, if this turns out to be the
            // last fragment. NOT layoutFragmentFrame.maxY: measured on
            // "alpha\nbravo\n", the final fragment's frame is y 16..48 and holds
            // two line fragments -- "bravo" at 0..16 and the empty line at
            // 16..32 -- so its maxY is a whole line below where that empty line
            // actually starts. Take the last line fragment's own origin instead,
            // which stays correct when the preceding line wraps.
            if let lastLine = fragment.textLineFragments.last {
                trailingLineTop = fragment.layoutFragmentFrame.minY + lastLine.typographicBounds.minY
            } else {
                trailingLineTop = fragment.layoutFragmentFrame.maxY
            }

            if fragment.rangeInElement.endLocation
                .compare(contentManager.documentRange.endLocation) != .orderedAscending {
                reachedDocumentEnd = true
            }
            return true
        }

        // A document ending in a newline has one more line than the loop above
        // draws numbers for. TextKit 2 carries that empty final line inside the
        // preceding fragment rather than giving it one of its own, so the loop
        // never sees a fragment to label and the caret sits there unnumbered --
        // which is how nearly every text file ends. Only when the last fragment
        // was actually reached, so scrolling away from the end leaves no stray
        // number behind.
        if index.hasTrailingEmptyLine, reachedDocumentEnd, let top = trailingLineTop {
            draw(
                lineNumber: index.lineCount,
                atFragmentTop: top,
                in: textView,
                attributes: attributes
            )
        }
    }

    /// Draws one right-aligned number level with a fragment whose top edge is at
    /// `fragmentTop` in the text view's coordinates.
    private func draw(
        lineNumber: Int,
        atFragmentTop fragmentTop: CGFloat,
        in textView: NSTextView,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let inTextView = NSPoint(x: 0, y: fragmentTop + textView.textContainerInset.height)
        let y = convert(inTextView, from: textView).y

        let label = "\(lineNumber)" as NSString
        let width = labelWidth(digits: label.length)
        label.draw(
            at: NSPoint(x: bounds.maxX - width - horizontalPadding, y: y),
            withAttributes: attributes
        )
    }

    // MARK: - Gutter width

    /// Resizing the gutter must not happen inside the draw pass. Assigning
    /// ruleThickness invalidates the enclosing scroll view's layout, and doing
    /// that mid-draw puts NSScrollView into a tile/draw loop that never settles --
    /// the visible symptom is that the gutter paints and the text never does.
    ///
    /// So measure here and hop to the next runloop turn only when the width
    /// actually changes, which is when the line count crosses a power of ten.
    /// This terminates: the redraw the new thickness triggers measures the same
    /// width again, finds it equal, and schedules nothing.
    private func scheduleThicknessUpdateIfNeeded(for index: LineIndex) {
        let wanted = thickness(forHighestLine: index.lineCount)
        guard !thicknessUpdateScheduled, abs(wanted - ruleThickness) > 0.5 else { return }

        thicknessUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.thicknessUpdateScheduled = false
            self.applyThickness(wanted)
        }
    }

    private func applyThickness(_ wanted: CGFloat) {
        guard abs(wanted - ruleThickness) > 0.5 else { return }
        ruleThickness = wanted
    }

    private func thickness(forHighestLine line: Int) -> CGFloat {
        let digits = max(2, String(line).count)
        return labelWidth(digits: digits) + horizontalPadding * 2
    }
}
