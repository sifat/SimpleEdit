# tree-sitter-java queries

`highlights.scm` is a **byte-for-byte copy** of the upstream file. Do not edit it.

| | |
| --- | --- |
| Upstream | https://github.com/tree-sitter/tree-sitter-java |
| Tag | v0.23.5 |
| Commit | `94703d5a6bed02b98e438d7cad1136c01a60ba2c` |
| Copied | 2026-09-11 |
| Licence | MIT, copyright Ayman Nadeem — see `LICENSE` beside this file |

The reasoning for vendoring rather than reading the grammar's own resource
bundle is in `../html/SOURCE.md`.

## Why v0.23.5

It is the newest tag there is; the repository has no 0.25 release. Java has no
external scanner, so the relative-path scanner hazard described in
`../css/SOURCE.md` cannot arise for this grammar at any version. The parser is
ABI 14, like every grammar here except PHP and SQL.

The query ships alone: upstream's `queries/` holds only `highlights.scm` and
`tags.scm`.

## Predicates

Only `#match?`, five times: four `^[A-Z]` tests that make the object of
`System.out` or `Math.max(…)` a type, and one `^_*[A-Z][A-Z\d_]+$` for constants.
All are evaluated. The constant pattern needs **two or more** characters, so a
single-letter generic such as `T` never matches it — and `T` is a
`type_identifier` anyway.

## Captures

Java needs more Java-only mapping than any other language here, because three
of its capture names would come out wrong under the shared table:

| Capture | Treatment | Why |
| --- | --- | --- |
| `@variable` | **unmapped** | the blanket `(identifier)` capture, as everywhere |
| `@function.method` | `function` | shared as `property`, because JavaScript always co-captures it with `@property`. Java's query has no `@property`, so under the shared row every method name would be blue |
| `@type`, `@type.builtin` | `type` | a type name, as in TypeScript and Python; the shared row is CSS's unit |
| `@variable.builtin` | `keyword` | only ever `this` |
| `@function.builtin` | `keyword` | only ever `super` |
| `@string.escape` | `string` via fallback | always inside a string literal, which covers it |
| `@operator` | `punctuation` | only ever the `@` of an annotation |

`this` and `super` are keywords in Java, and neither node is captured by
anything else, so colouring them as keywords cannot create an identical-range
tie.

Unlike JavaScript and Python, **class names are coloured**. The grammar knows
them from their position — declaration names and `type_identifier` — rather
than guessing from capitalisation.

One quirk worth knowing: `var` is parsed as a type identifier, so it colours as
a type.

## Keeping it in step with upstream

On a version bump, re-copy the file and diff. `QueryContractTests` asserts the
capture-name set is exactly the fifteen names below.

    @attribute  @comment  @constant  @constant.builtin  @function.builtin
    @function.method  @keyword  @number  @operator  @string  @string.escape
    @type  @type.builtin  @variable  @variable.builtin
