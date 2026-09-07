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
    case typescript

    public var title: String {
        switch self {
        case .plain: "None"
        case .html: "HTML"
        case .css: "CSS"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
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
        case .typescript: 4
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
        // Not "tsx": that needs the JSX query as a third fragment, and this
        // app does not vendor it.
        case .typescript: ["ts", "mts", "cts"]
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
    /// **A byte cap does not bound the worst case, and cannot.** These numbers
    /// buy an ordinary-file guarantee, not a guarantee:
    ///
    ///     JavaScript, library code       0.33 ms/KB
    ///     CSS, real stylesheets          0.55 ms/KB
    ///     JavaScript, dense component    0.95 ms/KB
    ///     HTML, markup with inline js    1.06 ms/KB
    ///     TypeScript, dense              1.07 ms/KB
    ///     HTML, tag-dense markup         1.28 ms/KB
    ///
    /// That table measures **capture density**, which is what the per-capture
    /// cost scales with. It is not what sets the worst case. The worst case is
    /// set by nesting depth and unbalanced brackets, both of which are
    /// QUADRATIC, so cost per KB is not a property of a language at all -- it
    /// is a property of the text. Measured at these caps:
    ///
    ///     HTML, 21845 unclosed `<b>` at 32 KB          429 ms
    ///     CSS, nested `:is(` at 64 KB                 2861 ms
    ///     TypeScript, ONE stray `(` in a 32 KB file     77 ms
    ///     JavaScript, ONE stray `(` in a 32 KB file     40 ms
    ///
    /// The third and fourth are the ones that matter, because they are not
    /// pathological input -- they are an ordinary file halfway through being
    /// typed. Doubling these caps was tried and reverted: it multiplied every
    /// one of those numbers by about four (HTML 429 -> 1726 ms, CSS 2861 ->
    /// 11436 ms) while buying nothing, because the C query loop that made
    /// realistic files 2-3x faster is worth about 1.05x on input shaped like
    /// this. Capture density is cheap now; nesting was never the part that got
    /// faster.
    ///
    /// So the honest statement is: these caps keep *typical* files inside a
    /// frame or two, and a hostile or half-typed file can still stall the main
    /// thread for a second or more. The fix for that is a time budget on both
    /// the parse and the query -- bounding the work rather than the input --
    /// not a smaller number here.
    ///
    /// CSS gets the larger cap because real stylesheets produce about a third
    /// the captures per KB that dense markup does.
    ///
    /// Injections do NOT make HTML worse per KB, which is worth stating because
    /// it is the opposite of what one expects: an inline script is less
    /// capture-dense than the markup around it, so a page with a large
    /// `<script>` measures *cheaper* per KB than the same page of pure markup.
    public var maximumLength: Int {
        switch self {
        case .plain: 0
        case .css: 64 * 1024
        case .html, .javascript, .typescript: 32 * 1024
        }
    }

    /// The query files to concatenate, in order, relative to the queries root.
    ///
    /// A list rather than one file per language because TypeScript's
    /// `highlights.scm` is not a whole query. It is a 35-line **fragment** --
    /// type names, type arguments, parameters and fifteen TypeScript-only
    /// keywords -- carrying no strings, comments, numbers, operators, brackets
    /// or any JavaScript keyword. Upstream states the composition itself, in
    /// tree-sitter-typescript's own `tree-sitter.json`:
    ///
    ///     "highlights": [
    ///       "queries/highlights.scm",
    ///       "node_modules/tree-sitter-javascript/queries/highlights.scm"
    ///     ]
    ///
    /// The order is upstream's and is preserved here. Loading the fragment on
    /// its own is not a reduced-fidelity option: it colours a few per cent of a
    /// file and fails **silently**, which looks broken rather than deliberately
    /// plain. Concatenating at load time is what lets both files stay
    /// byte-for-byte copies of a real upstream URL, each with its own tag
    /// pinned in its own SOURCE.md -- the property that makes a version bump a
    /// plain diff.
    public var queryFiles: [String] {
        guard let directory = queryDirectoryName else { return [] }
        let own = "\(directory)/highlights.scm"
        switch self {
        case .typescript: return [own, "javascript/highlights.scm"]
        default: return [own]
        }
    }

    /// The injections query, if this language embeds others.
    ///
    /// Only HTML does. The file marks the body of a `<script>` or `<style>`
    /// element and tags it with a language NAME -- tree-sitter's name, not
    /// ours; upstream is explicit that these are not standardised, which is why
    /// `init?(injectionName:)` exists rather than a rawValue lookup.
    public var injectionQueryFile: String? {
        switch self {
        case .html: "html/injections.scm"
        default: nil
        }
    }

    /// Maps an `injection.language` value from a query to a language we have.
    ///
    /// Deliberately not `SyntaxLanguage(rawValue:)`. These strings belong to the
    /// grammar that emitted them, and a grammar is free to rename them or to
    /// name something we have never heard of; an unknown name simply means that
    /// region stays plain.
    public init?(injectionName: String) {
        switch injectionName {
        case "javascript": self = .javascript
        case "css": self = .css
        default: return nil
        }
    }

    /// Subdirectory under `Resources/Queries/` holding this language's vendored
    /// files. Matches the grammar's canonical name, so this is the single
    /// string tying the enum to the filesystem.
    public var queryDirectoryName: String? {
        switch self {
        case .plain: nil
        case .html: "html"
        case .css: "css"
        case .javascript: "javascript"
        case .typescript: "typescript"
        }
    }
}
