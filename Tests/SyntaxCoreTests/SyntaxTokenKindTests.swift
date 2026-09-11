import Testing
@testable import SyntaxCore

@Suite("Capture names to token kinds")
struct SyntaxTokenKindTests {

    @Test("The HTML grammar's capture names all map")
    func htmlCaptureNames() {
        #expect(SyntaxTokenKind(captureName: "tag", in: .html) == .tag)
        #expect(SyntaxTokenKind(captureName: "attribute", in: .html) == .attribute)
        #expect(SyntaxTokenKind(captureName: "string", in: .html) == .string)
        #expect(SyntaxTokenKind(captureName: "comment", in: .html) == .comment)
        #expect(SyntaxTokenKind(captureName: "constant", in: .html) == .constant)
    }

    @Test("The CSS grammar's capture names all map")
    func cssCaptureNames() {
        #expect(SyntaxTokenKind(captureName: "keyword", in: .css) == .keyword)
        #expect(SyntaxTokenKind(captureName: "property", in: .css) == .property)
        #expect(SyntaxTokenKind(captureName: "function", in: .css) == .function)
    }

    /// Four capture names deliberately land on a kind that already existed.
    /// Written out one by one because each is a judgement call rather than an
    /// oversight, and a future reader deleting one would change what the editor
    /// looks like without touching any code that mentions colour.
    @Test("Some CSS captures deliberately share a kind with something else")
    func deliberateCollapses() {
        // A CSS custom property (--brand) is a property.
        #expect(SyntaxTokenKind(captureName: "variable", in: .css) == .property)
        // A number and the unit stuck to it are both literal values.
        #expect(SyntaxTokenKind(captureName: "number", in: .css) == .constant)
        #expect(SyntaxTokenKind(captureName: "type", in: .css) == .constant)
        // Combinators are punctuation that happens to mean something.
        #expect(SyntaxTokenKind(captureName: "operator", in: .css) == .punctuation)
        // And a hex colour reaches .string the same way punctuation.bracket
        // reaches .punctuation -- nothing claims the full dotted name.
        #expect(SyntaxTokenKind(captureName: "string.special", in: .css) == .string)
    }

    /// tree-sitter names are hierarchical and an unclaimed leaf falls back to
    /// its parent. `punctuation.bracket` is the only dotted name HTML actually
    /// emits, and nothing claims it specifically.
    @Test("A dotted name falls back to its parent")
    func dottedFallback() {
        #expect(SyntaxTokenKind(captureName: "punctuation.bracket", in: .html) == .punctuation)
        #expect(SyntaxTokenKind(captureName: "punctuation.delimiter.special", in: .html) == .punctuation)
    }

    /// ...but a longer match wins, which is how a mismatched closing tag gets
    /// its own colour instead of looking like an ordinary tag.
    @Test("A more specific name beats its parent")
    func longestMatchWins() {
        #expect(SyntaxTokenKind(captureName: "tag", in: .html) == .tag)
        #expect(SyntaxTokenKind(captureName: "tag.error", in: .html) == .invalid)
    }

    /// The degradation path: a grammar bump that introduces a capture nobody
    /// has mapped leaves that text uncoloured rather than breaking.
    @Test("An unknown name maps to nothing rather than guessing")
    func unknownNames() {
        #expect(SyntaxTokenKind(captureName: "constructor", in: .css) == nil)
        #expect(SyntaxTokenKind(captureName: "markup.heading", in: .css) == nil)
        #expect(SyntaxTokenKind(captureName: "", in: .css) == nil)
    }

    @Test("The JavaScript grammar's capture names all map")
    func javaScriptCaptureNames() {
        #expect(SyntaxTokenKind(captureName: "keyword", in: .javascript) == .keyword)
        #expect(SyntaxTokenKind(captureName: "function", in: .javascript) == .function)
        #expect(SyntaxTokenKind(captureName: "number", in: .javascript) == .constant)
        #expect(SyntaxTokenKind(captureName: "string.special", in: .javascript) == .string)
        #expect(SyntaxTokenKind(captureName: "punctuation.special", in: .javascript) == .punctuation)
        // Co-captured with @property over the same range, so it must agree.
        #expect(SyntaxTokenKind(captureName: "function.method", in: .javascript) == .property)
    }

    /// The reason the initializer takes a language at all. `@variable` is a CSS
    /// custom property and any identifier whatsoever in JavaScript; one global
    /// table cannot mean both, and the JavaScript reading painted every
    /// identifier in the file blue.
    @Test("One capture name reads differently in two languages")
    func languageScopedNames() {
        #expect(SyntaxTokenKind(captureName: "variable", in: .css) == .property)
        #expect(SyntaxTokenKind(captureName: "variable", in: .javascript) == nil)
    }

    /// A nil entry has to STOP the dotted walk. If it read as an ordinary
    /// lookup miss, `variable` would fall through to the shared table's
    /// `.property` row and the override would do nothing at all.
    @Test("An unmapped name stops the walk instead of falling through")
    func nilOverrideStopsTheWalk() {
        #expect(SyntaxTokenKind(captureName: "variable.builtin", in: .javascript) == nil)
        #expect(SyntaxTokenKind(captureName: "constructor", in: .javascript) == nil)
        #expect(SyntaxTokenKind(captureName: "embedded", in: .javascript) == nil)
        // ...and the override is scoped to its own language, not global.
        #expect(SyntaxTokenKind(captureName: "constructor", in: .css) == nil)
        #expect(SyntaxTokenKind(captureName: "property", in: .javascript) == .property)
    }

    /// Python reads `type`, `variable` and `constructor` the way TypeScript
    /// does, and `type` still means a unit in CSS.
    @Test("Python's overrides match TypeScript's and stay scoped")
    func pythonOverrides() {
        #expect(SyntaxTokenKind(captureName: "type", in: .python) == .type)
        #expect(SyntaxTokenKind(captureName: "type", in: .css) == .constant)
        #expect(SyntaxTokenKind(captureName: "variable", in: .python) == nil)
        #expect(SyntaxTokenKind(captureName: "constructor", in: .python) == nil)
        #expect(SyntaxTokenKind(captureName: "escape", in: .python) == nil)
        #expect(SyntaxTokenKind(captureName: "function.builtin", in: .python) == .function)
        #expect(SyntaxTokenKind(captureName: "punctuation.special", in: .python) == .punctuation)
    }

    @Test("Shell's captures land on existing kinds, and embedded stays unmapped")
    func shellCaptures() {
        #expect(SyntaxTokenKind(captureName: "embedded", in: .shell) == nil)
        #expect(SyntaxTokenKind(captureName: "number", in: .shell) == .constant)
        #expect(SyntaxTokenKind(captureName: "operator", in: .shell) == .punctuation)
        #expect(SyntaxTokenKind(captureName: "property", in: .shell) == .property)
        #expect(SyntaxTokenKind(captureName: "function", in: .shell) == .function)
    }
}
