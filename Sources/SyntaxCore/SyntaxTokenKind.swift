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
    case type
    case invalid

    /// tree-sitter capture names are dotted and hierarchical, and the convention
    /// is that an unknown leaf falls back to its parent: `punctuation.bracket`
    /// is a `punctuation` if nothing claims the full name. Longest match wins,
    /// so `tag.error` can mean something different from `tag`.
    ///
    /// The language is part of the question, not decoration. Grammars reuse the
    /// same capture name for genuinely different things -- `@variable` is a CSS
    /// custom property and *any identifier at all* in JavaScript -- so a single
    /// global table cannot serve both. A language's own entry is consulted
    /// first, and an entry mapping to nil **stops the walk** rather than
    /// falling through to the shared table. That distinction is the whole
    /// point: written as an ordinary lookup miss, JavaScript's `variable` would
    /// fall through to the shared `.property` row and paint every identifier in
    /// the file blue, which is the exact bug this exists to prevent.
    ///
    /// Returns nil for names nothing claims, which is how a future grammar
    /// degrades instead of breaking.
    public init?(captureName: String, in language: SyntaxLanguage) {
        var components = captureName.split(separator: ".").map(String.init)
        while !components.isEmpty {
            let name = components.joined(separator: ".")
            if let override = Self.overrides[language]?[name] {
                guard let kind = override else { return nil }
                self = kind
                return
            }
            if let kind = Self.byCaptureName[name] {
                self = kind
                return
            }
            components.removeLast()
        }
        return nil
    }

    /// Names one language reads differently from the rest. The value is
    /// `SyntaxTokenKind?`: a nil VALUE means "this language deliberately does
    /// not colour this", which is different from the name being absent.
    ///
    /// JavaScript's three are all the same shape -- a capture that fires over
    /// the *same range* as another capture, so colouring it would make the
    /// winner depend on a sort tie-break rather than on a decision:
    ///
    /// - `variable` is the blanket `(identifier)` capture, roughly a fifth of
    ///   all captures in real code, and it collides with `function` on every
    ///   called name. Dropping it leaves identifiers in the ordinary text
    ///   colour, which is what HTML body text and CSS plain values already do.
    /// - `constructor` is `^[A-Z]` on any identifier, so it fires over the same
    ///   range as `function` for every capitalised function and over `constant`
    ///   for every SCREAMING_CAPS name. It cannot be collapsed onto either
    ///   without recreating the ambiguity, so it is dropped too.
    /// - `embedded` covers a whole `${...}` substitution *including* the
    ///   expression inside it. Because overlaps resolve outermost-first, giving
    ///   it a colour would swallow every token within it.
    ///
    /// With those three unmapped, no range in real JavaScript carries two
    /// different kinds, so the token list is decided by the grammar rather than
    /// by the sort.
    /// TypeScript inherits JavaScript's three for the same reasons -- its query
    /// is JavaScript's with a fragment in front -- and adds one of its own.
    /// `type` is the one capture name that means something genuinely different
    /// in two grammars: in CSS it is the `px` in `10px`, which the shared table
    /// maps to `.constant` so that a number and its unit colour as one thing;
    /// in TypeScript it is a type NAME, and painting `HttpResponse` the same
    /// teal as the number `10` is the most visible way to look wrong.
    ///
    /// Because TypeScript maps `type` and leaves `constructor` unmapped, a
    /// capitalised identifier -- captured as `@type` by the fragment and
    /// `@constructor` by JavaScript's half, over the same range -- resolves to
    /// the type colour rather than to nothing. So `new HttpError()` is coloured
    /// in a `.ts` file and plain in a `.js` one, which is not an inconsistency:
    /// only the TypeScript grammar actually knows it is a type.
    private static let overrides: [SyntaxLanguage: [String: SyntaxTokenKind?]] = [
        .javascript: [
            "variable": nil,
            "constructor": nil,
            "embedded": nil,
        ],
        .typescript: [
            "variable": nil,
            "constructor": nil,
            "embedded": nil,
            "type": .type,
        ],
        // Python needs exactly TypeScript's table, for the same reasons in the
        // same places: `(identifier) @variable` is the blanket capture,
        // `@constructor` is the `^[A-Z]` naming guess, and `@type` is an
        // annotation name. `@embedded` is an f-string interpolation -- always
        // inside a `(string)`, which covers it whole -- and is unmapped for
        // consistency rather than because it could ever be seen.
        .python: [
            "variable": nil,
            "constructor": nil,
            "embedded": nil,
            "type": .type,
        ],
        // Shell needs no overrides except this one, and even this one is
        // already the default -- nothing in the shared table claims `embedded`.
        // It is written out because the capture covers a whole `$(...)`,
        // `<(...)` or `${...}` including the command inside it, and outermost-
        // wins means mapping it would swallow that command. Explicit here, a
        // future shared row for `embedded` cannot reach it by accident.
        .shell: [
            "embedded": nil,
        ],
        // Java differs from JavaScript in three ways, and each is a place the
        // shared table would colour Java wrongly.
        //
        // - `function.method` is shared as `.property`, because in JavaScript
        //   it always coincides with a `@property` capture. Java's query has no
        //   `@property` at all: a method declaration or call is captured ONLY
        //   as `function.method`, so under the shared row every method name
        //   in a Java file would be blue rather than a function.
        // - `type` is a type name, as in TypeScript and Python; the shared row
        //   is CSS's unit.
        // - `variable.builtin` is only `this`, and `function.builtin` only
        //   `super`. Both are keywords in Java, and neither node is captured by
        //   anything else, so colouring them as keywords cannot create a tie.
        //   Left to the shared table, `this` would be plain (it inherits
        //   `variable`) and `super` indigo.
        //
        // `variable` is the blanket `(identifier)` capture, unmapped as
        // everywhere. Unlike JavaScript and Python, Java class names ARE
        // coloured: the grammar captures them as `@type` from their position,
        // not from a capitalisation guess.
        .java: [
            "variable": nil,
            "variable.builtin": .keyword,
            "function.builtin": .keyword,
            "function.method": .function,
            "type": .type,
        ],
        // PHP's table is Java's plus three names Java's query never emits, and
        // one that means something different here.
        //
        // - `variable` is NOT the blanket identifier capture it is everywhere
        //   else: PHP variables carry a `$`, so the grammar captures exactly
        //   `$foo` and nothing else. Measured over 45,000 WordPress and Drupal
        //   files, it collides with only one other capture -- `property`, over
        //   the identical range, on `$obj->$name` -- and both map to the same
        //   kind, so the duplicate collapses instead of being decided by a
        //   tie-break. Leaving it unmapped would instead leave every variable
        //   in a PHP file uncoloured, which is most of the file.
        // - `module` is a namespace name and `module.builtin` the `namespace`
        //   of a relative name. A namespace reads as a type here; the keyword
        //   reads as a keyword.
        // - `constructor` is `__construct` and the class name in `new Foo`.
        //   Both are type-ish, and `type` is what the same range usually
        //   carries anyway, so agreeing with it avoids a tie-break.
        //
        // `type.builtin` is `static`, `self` and the primitive types; it has no
        // row because the dotted walk reaches `type` and that is the right
        // answer. It is gated by `#any-of?`, which this app evaluates -- were
        // it not, 41,448 ordinary class names in the Drupal corpus would be
        // captured as builtins.
        .php: [
            "variable": .property,
            "variable.builtin": .keyword,
            "function.builtin": .keyword,
            "function.method": .function,
            "type": .type,
            "constructor": .type,
            "module": .type,
            "module.builtin": .keyword,
        ],
        // SQL's query is the only vendored one written for Neovim rather than
        // for tree-sitter's own tooling, and it shows in the capture names:
        // half of them are Neovim's vocabulary, which no other grammar here
        // uses. Each is mapped to the nearest thing this app already has.
        //
        // - `conditional` (CASE/WHEN/THEN/ELSE), `storageclass` (TEMPORARY,
        //   MATERIALIZED) and `type.qualifier` (UNIQUE, CASCADE, CHECK) are all
        //   keywords by any reading; only Neovim's themes separate them.
        // - `field` is a column name and `parameter` a `$1` placeholder; both
        //   read as the identifiers they are, which is `property` here.
        // - `boolean` and `float` are literals, like `number`.
        // - `type` must be overridden because the shared row means CSS's unit:
        //   in SQL it is a table or object name.
        // - `spell` is unmapped ON PURPOSE. It is not a colour at all -- it
        //   marks regions for Neovim's spell checker, and it is captured over
        //   the same comments as `@comment`. Colouring it would put a second
        //   kind on an identical range and leave the winner to a tie-break.
        .sql: [
            "boolean": .constant,
            "conditional": .keyword,
            "field": .property,
            "float": .constant,
            "parameter": .property,
            "spell": nil,
            "storageclass": .keyword,
            "type": .type,
            "type.qualifier": .keyword,
        ],
    ]

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
        // JavaScript. `function.method` is always co-captured with `property`
        // over the identical range -- `obj.doThing()` -- so it has to agree
        // with it, or the winner would be a tie-break rather than a decision.
        "function.method": .property,
    ]
}
