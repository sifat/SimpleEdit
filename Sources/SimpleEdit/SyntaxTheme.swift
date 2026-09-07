import AppKit
import SyntaxCore

/// Token kind to colour.
///
/// Deliberately a function and not a protocol, a struct hierarchy or a plist.
/// The app has three other colours in total; a theme abstraction here would be
/// scaffolding around a lookup table. If a second theme is ever wanted this
/// becomes a method on a value type and no call site moves.
///
/// System colours rather than hand-rolled dynamic ones: they already carry
/// tuned Aqua and Dark Aqua variants and honour Increase Contrast. Because they
/// are dynamic, and because rendering attributes resolve colours at draw time
/// (measured -- see the spike notes in the README), switching appearance
/// recolours the document with no invalidation, no observer and no code here.
///
/// Never cache a resolved colour or a CGColor: those snapshot the appearance
/// that was current when they were made.
enum SyntaxTheme {

    static func color(for kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .tag: .systemBlue
        case .attribute: .systemPurple
        case .string: .systemRed
        case .comment: .systemGreen
        case .constant: .systemTeal
        case .punctuation: .tertiaryLabelColor
        // CSS. `property` shares blue with `tag` on purpose: a CSS selector is
        // the same sort of thing an HTML tag name is, and the two never appear
        // in the same position, so a second blue costs nothing and one fewer
        // colour is easier to read.
        case .keyword: .systemPink
        case .property: .systemBlue
        case .function: .systemIndigo
        // TypeScript. Shares purple with `attribute` the way `property` shares
        // blue with `tag`: the two never occur in the same file, since nothing
        // in TypeScript is captured as an attribute.
        case .type: .systemPurple
        case .invalid: .systemOrange
        }
    }
}
