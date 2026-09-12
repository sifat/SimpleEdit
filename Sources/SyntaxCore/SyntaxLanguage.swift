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
    case python
    case shell
    case java
    case php
    case sql

    public var title: String {
        switch self {
        case .plain: "None"
        case .html: "HTML"
        case .css: "CSS"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .python: "Python"
        case .shell: "Shell"
        case .java: "Java"
        case .php: "PHP"
        case .sql: "SQL"
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
        case .python: 5
        case .shell: 6
        case .java: 7
        case .php: 8
        case .sql: 9
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
        // .pyi is a typed stub and .pyw a windowed script; both are plain Python.
        case .python: ["py", "pyi", "pyw"]
        // The grammar is Bash. zsh files parse well enough for highlighting --
        // zsh-only constructs such as glob qualifiers become error nodes and
        // stay plain -- and `.command` is macOS's double-clickable script.
        case .shell: ["sh", "bash", "zsh", "command"]
        case .java: ["java"]
        // `.phtml` is the other conventional extension for a PHP template.
        // Drupal's `.module`, `.inc`, `.install` and `.theme` are PHP too, but
        // `.inc` in particular is not PHP anywhere else, so they are left out.
        case .php: ["php", "phtml"]
        case .sql: ["sql"]
        }
    }

    /// Files recognised by their whole name, because they have no extension.
    ///
    /// `URL.pathExtension` of `.zshrc` is the empty string -- a leading dot is
    /// not an extension separator -- so detection by extension alone misses
    /// every shell dotfile, which are the shell files a text editor is most
    /// likely to be pointed at. Matched case-insensitively, like extensions.
    public var fileNames: [String] {
        switch self {
        case .shell:
            [".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".bash_aliases",
             ".profile", ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout"]
        default: []
        }
    }

    /// Detection from a file's name: an exact whole-name match first, then the
    /// extension. This is what the editor calls; `init?(fileExtension:)` is
    /// the second half of it.
    public init?(fileName: String) {
        let normalised = fileName.lowercased()
        if let match = Self.allCases.first(where: { $0.fileNames.contains(normalised) }) {
            self = match
            return
        }
        self.init(fileExtension: (fileName as NSString).pathExtension)
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
    /// The cap is NOT what bounds the worst case -- `SyntaxParser.defaultBudget`
    /// is. A byte count cannot bound it: the worst case is set by nesting
    /// depth and unbalanced brackets, both quadratic, and a file halfway
    /// through being typed passes through those shapes routinely. The time
    /// budget cuts such a document to plain at ~80 ms instead of freezing for
    /// seconds; without it, these caps were half this size and still let a
    /// 32 KB file of unclosed tags cost 400 ms per keystroke.
    ///
    /// What the cap does bound is the *ordinary* cost paid on every keystroke,
    /// and it is sized so that a typical file at the cap finishes well inside
    /// the budget on hardware slower than this. Measured in release, which is
    /// what the app ships (debug is 4-5x slower and was what an earlier
    /// version of this table was measured in):
    ///
    ///     Java, JDK and Android sources  0.07-0.14 ms/KB
    ///     JavaScript, library code       0.07 ms/KB
    ///     CSS, real stylesheets          0.12 ms/KB
    ///     Shell, real bash scripts       0.10-0.16 ms/KB
    ///     Python, standard library       0.14-0.20 ms/KB
    ///     JavaScript, dense component    0.21 ms/KB
    ///     HTML, markup with inline js    0.21 ms/KB
    ///     TypeScript, dense              0.22 ms/KB
    ///     HTML, tag-dense markup         0.26 ms/KB
    ///     Java, dense streams and lambdas 0.32 ms/KB
    ///     Shell, zsh-specific syntax     0.37 ms/KB
    ///     Shell, dense bash              0.38 ms/KB
    ///     Python, dense comprehensions   0.49 ms/KB
    ///
    /// Python is the awkward one. Real Python is cheap -- in CSS territory --
    /// and real Python files are often large: argparse.py is 100 KB, typing.py
    /// 130 KB. On that evidence alone it would earn CSS's 128 KB. But dense
    /// Python, all comprehensions and short names, is the most expensive
    /// ordinary code measured in any language, and at 128 KB it would cost
    /// 63 ms here -- close enough to the budget that slower hardware would cut
    /// a legitimate file. So it caps at 64 KB with the others, and large
    /// standard-library modules stay plain. Java makes the same trade for the
    /// same reason: real Java is the cheapest code measured anywhere, but dense
    /// Java at 128 KB is 40 ms, so JDK files such as HashMap.java (95 KB) stay
    /// plain too. The comment on
    /// `SyntaxParser.defaultBudget` is why that trade goes this way round.
    ///
    /// So a 64 KB file of the densest markup is ~17 ms here and perhaps 40 ms
    /// on an old Intel machine -- half the budget, which is the headroom a
    /// legitimate file needs so that it is never the one being cut.
    ///
    /// CSS gets the larger cap and earns it: real stylesheets produce about
    /// half the captures per KB that dense markup does.
    ///
    /// Above the cap nothing is attempted, and that is deliberate rather than
    /// lazy: a document that can never finish inside the budget would
    /// otherwise pay the whole budget on every keystroke only to be cut each
    /// time.
    public var maximumLength: Int {
        switch self {
        case .plain: 0
        case .css: 128 * 1024
        case .html, .javascript, .typescript, .python, .shell, .java: 64 * 1024
        // PHP pays for two grammars, not one: the file is parsed as PHP, and
        // the HTML between its `?>` and `<?php` is parsed again as one combined
        // document. A 64 KB template of dense markup and dense PHP measures
        // 29 ms a keystroke here -- the same bar dense Python (31 ms) already
        // sets at this cap -- and real templates are far cheaper: WordPress's
        // 62 KB media-template.php is 14 ms.
        case .php: 64 * 1024
        // SQL is the one language whose cap is set by BROKEN files rather than
        // by dense ones, and it is half everything else's because of what a
        // real .sql file is. Dense hand-written SQL is cheap -- 64 KB of it
        // measures 14 ms -- but the .sql files that exist on disk are database
        // dumps, and this grammar cannot parse a mysqldump (see
        // Resources/Queries/sql/SOURCE.md). Error recovery over one enormous
        // statement is what costs, and the cost is superlinear in how much of
        // that statement is in the file. Measured on a real 71 KB dump whose
        // longest line is 70,081 characters, one INSERT with hundreds of rows:
        //
        //     32 KB  7.8 ms   0.25 ms/KB
        //     48 KB 16.1 ms   0.34 ms/KB
        //     56 KB 35.0 ms   0.63 ms/KB
        //     64 KB 51.8 ms   0.81 ms/KB
        //
        // At 64 KB that is 130 ms on hardware 2.5x slower -- past the budget,
        // so the document would be cut to plain on every attempt. At 32 KB it
        // is about 20 ms there, which is the headroom every other cap has.
        case .sql: 32 * 1024
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
        // PHP's is `injections-text.scm`, which upstream ships separately from
        // `injections.scm` precisely because it is the one a template editor
        // wants: it marks every `(text)` node -- the HTML around the PHP -- as
        // one COMBINED injection. `injections.scm` is deliberately not
        // vendored; it injects phpdoc into comments and names a heredoc's
        // language after its terminator, and this app has neither grammar.
        case .php: "php/injections-text.scm"
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
        case "html": self = .html
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
        case .python: "python"
        case .shell: "bash"
        case .java: "java"
        case .php: "php"
        case .sql: "sql"
        }
    }
}
