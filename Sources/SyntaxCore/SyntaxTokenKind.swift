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
    case keyword
    case property
    case function
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

    /// The union of every vendored query's capture names. Adding a language
    /// means adding names here, not editing any `.scm` -- which is what keeps
    /// the vendored files byte-for-byte diffable against upstream.
    ///
    /// Several names deliberately collapse onto a kind that already exists
    /// rather than earning one of their own:
    ///
    /// - `variable` is CSS's name for a custom property (`--brand`), which this
    ///   app has no reason to distinguish from any other property. It also
    ///   removes an ordering hazard: `--brand` is captured as *both* `property`
    ///   and `variable`, and two captures over one range with two different
    ///   kinds would leave the winner to `SyntaxTokenList`'s tie-break, which is
    ///   arbitrary. Mapping them together makes the duplicate identical, so it
    ///   collapses deterministically.
    /// - `number` and `type` are both literal values in CSS -- `10` and the `px`
    ///   after it -- so both are `constant`, and `10px` colours as one thing.
    /// - `operator` is CSS's `>`, `~`, `+` and friends. They are punctuation
    ///   that happens to mean something; nothing is gained by a separate colour.
    private static let byCaptureName: [String: SyntaxTokenKind] = [
        // HTML
        "tag": .tag,
        "tag.error": .invalid,
        "attribute": .attribute,
        "string": .string,
        "comment": .comment,
        "constant": .constant,
        "punctuation": .punctuation,
        // CSS
        "keyword": .keyword,
        "property": .property,
        "variable": .property,
        "function": .function,
        "number": .constant,
        "type": .constant,
        "operator": .punctuation,
    ]
}
