import AppKit

/// A line-number gutter driven by TextKit 2 layout fragments.
///
/// Each NSTextLayoutFragment corresponds to one logical line (a paragraph), which
/// may wrap onto several visual lines, so drawing one number per fragment gives
/// the numbering people expect: wrapped continuations are not numbered.
final class LineNumberRulerView: NSRulerView {

    private weak var textView: NSTextView?

    /// UTF-16 offsets at which each line begins. Rebuilt lazily so a burst of
    /// keystrokes costs one rebuild at the next draw rather than one per edit.
    private var lineStarts: [Int] = [0]
    private var lineStartsAreStale = true

    /// Above this size the O(n) line-start scan stops being worth it on every
    /// edit, and the gutter turns itself off rather than making typing lurch.
    private static let maximumDocumentBytes = 8 * 1024 * 1024

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let horizontalPadding: CGFloat = 6

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

    @objc private func textDidChange() {
        refreshLineIndex()
    }

    @objc private func viewportDidChange() {
        needsDisplay = true
    }

    /// Call after loading a document, since a programmatic `string` assignment
    /// does not post NSText.didChangeNotification.
    func documentDidLoad() {
        refreshLineIndex()
    }

    /// Rebuilds the line index and resizes the gutter.
    ///
    /// This must happen OUTSIDE drawHashMarksAndLabels. Assigning ruleThickness
    /// invalidates the enclosing scroll view's layout, and doing that from inside
    /// a draw pass puts NSScrollView into a tile/draw loop that never settles --
    /// the visible symptom is that the gutter paints and the text never does.
    private func refreshLineIndex() {
        lineStartsAreStale = true
        rebuildLineStartsIfNeeded()
        updateThickness(forHighestLine: lineStarts.count)
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

        guard !lineStarts.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // Deliberately NOT .ensuresLayout. Forcing TextKit 2 to lay out from inside
        // the ruler's draw pass re-enters the layout system while the text view is
        // mid-draw, and the text then never paints. Only ever read fragments the
        // viewport has already laid out.
        layoutManager.enumerateTextLayoutFragments(
            from: viewport.location,
            options: []
        ) { fragment in
            let origin = fragment.rangeInElement.location
            guard origin.compare(viewport.endLocation) != .orderedDescending else { return false }

            let offset = contentManager.offset(from: contentManager.documentRange.location, to: origin)
            let number = lineNumber(containing: offset)

            let frame = fragment.layoutFragmentFrame
            let inTextView = NSPoint(x: 0, y: frame.minY + textView.textContainerInset.height)
            let y = convert(inTextView, from: textView).y

            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: bounds.maxX - size.width - horizontalPadding, y: y),
                withAttributes: attributes
            )
            return true
        }
    }

    // MARK: - Line starts

    private func rebuildLineStartsIfNeeded() {
        guard lineStartsAreStale, let textView else { return }
        lineStartsAreStale = false

        let text = textView.string as NSString
        guard text.length <= Self.maximumDocumentBytes else {
            lineStarts = [0]
            return
        }

        var starts: [Int] = [0]
        var searchFrom = 0
        while searchFrom < text.length {
            let found = text.range(
                of: "\n",
                options: [],
                range: NSRange(location: searchFrom, length: text.length - searchFrom)
            )
            guard found.location != NSNotFound else { break }
            searchFrom = found.location + found.length
            starts.append(searchFrom)
        }
        lineStarts = starts
    }

    /// Binary search: which 1-based line contains this UTF-16 offset?
    private func lineNumber(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }

    private func updateThickness(forHighestLine line: Int) {
        let digits = max(2, String(line).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: font]).width + horizontalPadding * 2
        if abs(width - ruleThickness) > 0.5 {
            ruleThickness = width
        }
    }
}
