# tree-sitter-javascript queries

`highlights.scm` is a **byte-for-byte copy** of the upstream file. Do not edit it.

| | |
| --- | --- |
| Upstream | https://github.com/tree-sitter/tree-sitter-javascript |
| Tag | v0.23.1 |
| Commit | `3a837b6f3658ca3618f2022f8707e29739c91364` |
| Copied | 2026-09-07 |
| Licence | MIT — see `LICENSE` beside this file |

The reasoning for vendoring rather than reading the grammar's own resource
bundle is in `../html/SOURCE.md`.

## Why v0.23.1

There is no v0.23.2 — the grammars version independently, so JavaScript's 0.23
train stops one patch behind the pinned HTML and CSS. Of the tags that exist,
0.23.1 is the only recent one whose manifest is not booby-trapped:

- **v0.25.0** carries the relative-path scanner hazard described in
  `../css/SOURCE.md`.
- **v0.23.0** is worse, and fails every time rather than sometimes: its
  `sources:` list still holds the generator's placeholder comment,
  `// NOTE: if your language has an external scanner, add it here.`, so
  `src/scanner.c` is dropped unconditionally even though the file is present.
- **v0.23.1** lists `src/parser.c` and `src/scanner.c` unconditionally.

Nothing is given up by staying here: `highlights.scm` is byte-identical between
v0.23.1 and v0.25.0.

Two smaller traps, recorded because both cost time to find:

- The product is `TreeSitterJavaScript` with a **capital S**. v0.23.0 spelled it
  `TreeSitterJavascript`, so a snippet copied from that tag will not compile.
- Only `highlights.scm` is vendored. Upstream's `queries/` also ships
  `highlights-jsx.scm`, `highlights-params.scm`, `injections.scm`, `locals.scm`
  and `tags.scm`. `SyntaxLanguage.queryFiles` names exactly the files that are
  loaded, and the app claims `.js`/`.mjs`/`.cjs` but **not** `.jsx`,
  which would need the JSX query.

## Captures this app does not colour

Three of the nineteen captures are deliberately left unmapped, and
`SyntaxTokenKind.overrides` holds the reasoning. All three are the same shape —
a capture that fires over the *same range* as another capture, so colouring it
would make the winner depend on a sort tie-break rather than on a decision:

| Capture | Why not |
| --- | --- |
| `@variable` | the blanket `(identifier)` capture — about a fifth of all captures in real code, and it collides with `@function` on every called name |
| `@constructor` | `^[A-Z]` on any identifier, so it overlaps `@function` on capitalised functions and `@constant` on SCREAMING_CAPS |
| `@embedded` | covers a whole `${…}` substitution including its contents, which outermost-wins would swallow |

`@variable` is also why `SyntaxTokenKind` takes a language: CSS uses the same
name for a custom property, where it *is* coloured.

## Predicates

The query uses `#match?`, `#eq?` and `#is-not?`. The first two are evaluated.
`#is-not? local` always passes, because the app supplies no group-membership
provider and `locals.scm` is not loaded — so a locally shadowed `require` is
still coloured as a builtin. That is a known and accepted inaccuracy; loading
locals would mean a second query and a scope resolver.

## Keeping it in step with upstream

On a grammar version bump, re-copy the file and diff. `QueryContractTests`
asserts the capture-name set is exactly the nineteen names below, so a query
that gains or loses a capture fails the test suite rather than quietly changing
what is coloured.

    @comment  @constant  @constant.builtin  @constructor  @embedded  @function
    @function.builtin  @function.method  @keyword  @number  @operator  @property
    @punctuation.bracket  @punctuation.delimiter  @punctuation.special  @string
    @string.special  @variable  @variable.builtin
