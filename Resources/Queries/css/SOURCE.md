# tree-sitter-css queries

`highlights.scm` is a **byte-for-byte copy** of the upstream file. Do not edit it.

| | |
| --- | --- |
| Upstream | https://github.com/tree-sitter/tree-sitter-css |
| Tag | v0.23.2 |
| Commit | `c0d581e32d183a536731ed6c3a72758b27e20411` |
| Copied | 2026-09-07 |
| Licence | MIT — see `LICENSE` beside this file |

The reasoning for vendoring rather than reading the grammar's own resource
bundle is in `../html/SOURCE.md`; it is the same reasoning, and it is not
repeated here.

## Why v0.23.2 and not v0.25.0

v0.25.0's `Package.swift` decides whether to compile the external scanner with

    if FileManager.default.fileExists(atPath: "src/scanner.c")

— a **relative** path, resolved against whatever working directory SwiftPM
happens to run the manifest in, which for a dependency is not its own checkout.
When that test comes out false the grammar builds without its scanner and the
only symptom is a link error for `tree_sitter_css_external_scanner_create`, or,
worse, a parser that silently mis-lexes. v0.23.2 lists `src/scanner.c`
unconditionally, and is the same release train as the pinned `tree-sitter-html`.

## Predicates

This is the first query in the project that carries predicates:

    ((property_name) @variable (#match? @variable "^--"))
    ((plain_value)   @variable (#match? @variable "^--"))

tree-sitter does not evaluate `#match?` itself — it hands the predicate to the
caller. Ignoring them is not "slightly less accurate", it is wrong in the other
direction: **every** `plain_value` in the file would be captured as `@variable`,
so `block` in `display: block` would be coloured. `SyntaxParser` therefore
resolves predicates through `ResolvingQueryMatchSequence`. `CSSParsingTests`
pins both halves of that behaviour.

## Keeping it in step with upstream

On a grammar version bump, re-copy the file and diff. `QueryContractTests`
asserts the capture-name set is exactly the thirteen names below, so a query
that gains or loses a capture fails the test suite rather than quietly changing
what is coloured.

    @comment  @tag  @operator  @string  @string.special  @attribute  @property
    @function  @variable  @keyword  @number  @type  @punctuation.delimiter

The remapping from these names to this app's own token kinds lives in Swift, in
`SyntaxTokenKind.init?(captureName:)`, so the `.scm` never needs editing.
