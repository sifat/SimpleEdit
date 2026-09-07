import Foundation

/// What a highlighted run of text *is*, in this app's own vocabulary.
///
/// Deliberately a closed enum rather than tree-sitter's raw capture strings.
/// Grammars disagree about capture names and add new ones between versions; a
/// closed set means a grammar bump can add a name we do not know, and the worst
/// that happens is that run stays uncoloured.
public enum SyntaxTokenKind: String, Sendable, CaseIterable {
    case tag
    case attribute
    case string
    case comment
    case constant
    case punctuation
    case invalid

    /// tree-sitter capture names are dotted and hierarchical, and the convention
    /// is that an unknown leaf falls back to its parent: `punctuation.bracket`
    /// is a `punctuation` if nothing claims the full name. Longest match wins,
    /// so `tag.error` can mean something different from `tag`.
    ///
    /// Returns nil for names nothing claims, which is how a future grammar
    /// degrades instead of breaking.
    public init?(captureName: String) {
        var components = captureName.split(separator: ".").map(String.init)
        while !components.isEmpty {
            if let kind = Self.byCaptureName[components.joined(separator: ".")] {
                self = kind
                return
            }
            components.removeLast()
        }
        return nil
    }

    /// The HTML grammar's whole capture set is the first six entries plus
    /// `punctuation.bracket`, which falls back to `punctuation`. Adding a
    /// language means adding names here, not editing any `.scm`.
    private static let byCaptureName: [String: SyntaxTokenKind] = [
        "tag": .tag,
        "tag.error": .invalid,
        "attribute": .attribute,
        "string": .string,
        "comment": .comment,
        "constant": .constant,
        "punctuation": .punctuation,
    ]
}
