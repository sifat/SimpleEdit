import Foundation

/// Which grammar, if any, a document is highlighted with.
///
/// `.plain` rather than `.none`: `SyntaxLanguage.none` collides with
/// `Optional.none` wherever the type is inferred, and the resulting errors are
/// baffling out of proportion to the saving.
public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case plain
    case html
    case css
    case javascript

    public var title: String {
        switch self {
        case .plain: "None"
        case .html: "HTML"
        case .css: "CSS"
        case .javascript: "JavaScript"
        }
    }

    /// Menu tag. Only ever used to get from a clicked item back to a case; what
    /// would be persisted is the raw string, so these carry no compatibility
    /// weight.
    public var tag: Int {
        switch self {
        case .plain: 0
        case .html: 1
        case .css: 2
        case .javascript: 3
        }
    }

    public init?(tag: Int) {
        guard let match = Self.allCases.first(where: { $0.tag == tag }) else { return nil }
        self = match
    }

    /// Lowercased, without the dot.
    public var fileExtensions: [String] {
        switch self {
        case .plain: []
        case .html: ["html", "htm"]
        case .css: ["css"]
        // Not "jsx": that needs the grammar's separate highlights-jsx.scm,
        // which this app does not vendor, and the plain query colours JSX
        // markup as ordinary expressions.
        case .javascript: ["js", "mjs", "cjs"]
        }
    }

    /// Detection is by extension alone. It cannot be by document type:
    /// EditorDocumentController deliberately reports every file as
    /// `public.text` so that extensionless files open at all, so the type
    /// carries no language information by the time a document exists.
    public init?(fileExtension: String) {
        let normalised = fileExtension.lowercased()
        guard !normalised.isEmpty else { return nil }
        guard let match = Self.allCases.first(where: { $0.fileExtensions.contains(normalised) })
        else { return nil }
        self = match
    }

    /// Documents longer than this, in UTF-16 units, are not highlighted at all.
    ///
    /// Per language because the cost is per language, and measured rather than
    /// guessed. Tokenising runs synchronously on the keystroke path, so these
    /// are chosen to hold the worst case near 60 ms:
    ///
    ///     CSS, real stylesheets          0.95 ms/KB
    ///     JavaScript, library code       0.72 ms/KB
    ///     JavaScript, dense component    2.31 ms/KB   <- what 32 KB is sized for
    ///
    /// The spread inside JavaScript is three-fold and is about token density,
    /// not file size: the cost is dominated by per-capture allocation inside
    /// swift-tree-sitter, so what matters is how many captures a KB produces.
    /// A file of long prose comments is cheap; a file of short chained calls is
    /// not. 32 KB keeps even the dense case near 74 ms.
    public var maximumLength: Int {
        switch self {
        case .plain: 0
        case .html, .css: 64 * 1024
        case .javascript: 32 * 1024
        }
    }

    /// Subdirectory under `Resources/Queries/`. Matches the grammar's canonical
    /// name, so this is the single string tying the enum to the filesystem.
    public var queryDirectoryName: String? {
        switch self {
        case .plain: nil
        case .html: "html"
        case .css: "css"
        case .javascript: "javascript"
        }
    }
}
