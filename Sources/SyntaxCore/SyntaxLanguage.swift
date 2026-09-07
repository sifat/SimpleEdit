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

    public var title: String {
        switch self {
        case .plain: "None"
        case .html: "HTML"
        case .css: "CSS"
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

    /// Subdirectory under `Resources/Queries/`. Matches the grammar's canonical
    /// name, so this is the single string tying the enum to the filesystem.
    public var queryDirectoryName: String? {
        switch self {
        case .plain: nil
        case .html: "html"
        case .css: "css"
        }
    }
}
