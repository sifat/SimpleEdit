# tree-sitter-python queries

`highlights.scm` is a **byte-for-byte copy** of the upstream file. Do not edit it.

| | |
| --- | --- |
| Upstream | https://github.com/tree-sitter/tree-sitter-python |
| Tag | v0.23.6 |
| Commit | `bffb65a8cfe4e46290331dfef0dbf0ef3679de11` |
| Copied | 2026-09-11 |
| Licence | MIT — see `LICENSE` beside this file |

The reasoning for vendoring rather than reading the grammar's own resource
bundle is in `../html/SOURCE.md`.

## Why v0.23.6

v0.25.0 carries the relative-path scanner hazard described in
`../css/SOURCE.md`. For Python that hazard is worse than for any other grammar
here: the external scanner is what turns indentation into blocks, so a build
that silently dropped it would fail to parse the body of nearly every function
and class. v0.23.6 lists `src/scanner.c` unconditionally.
`PythonParsingTests` includes a nested-indentation test that would fail
without the scanner.

The query ships alone: upstream's `queries/` holds only `highlights.scm` and
`tags.scm`. No injections, no locals, and — unlike TypeScript — no fragment to
compose.

## Predicates

Only `#match?`, three times: the `^[A-Z]` constructor guess, the
`^[A-Z][A-Z_]*$` constant guess, and one long alternation naming the builtin
functions. All three are evaluated. The builtins list is a regex rather than
`#any-of?`, which matters: `#any-of?` is not evaluated by `SyntaxParser` and
would pass unconditionally, colouring every called name as a builtin.

## Captures this app does not colour

| Capture | Why not |
| --- | --- |
| `@variable` | the blanket `(identifier)` capture, as in JavaScript |
| `@constructor` | the `^[A-Z]` naming guess, which overlaps `@constant`, `@function` and `@type` on the same ranges |
| `@embedded` | an f-string interpolation — always inside a `(string)`, which covers it whole |
| `@escape` | always inside a `(string)`, likewise |

The overrides are exactly TypeScript's, for the same reasons. The visible
consequence of `@constructor` is the same as in JavaScript: a class name in
`class Point:` has no colour of its own, because the grammar's only capture on
it is the naming guess.

## Two things that look like mistakes and are not

- **Word operators are grey.** Upstream captures `and`, `or`, `not`, `in` and
  `is` as `@operator`, and this app colours operators as punctuation.
- **`T` in `def f(x: T) -> T` is a type, not a constant.** It matches both the
  annotation pattern and the all-caps pattern over the identical range.
  `SyntaxTokenList` breaks identical-range ties by evidence: a constant that
  ties can only have come from a naming convention, so the syntactic position
  wins.

## Keeping it in step with upstream

On a version bump, re-copy the file and diff. `QueryContractTests` asserts the
capture-name set is exactly the seventeen names below.

    @comment  @constant  @constant.builtin  @constructor  @embedded  @escape
    @function  @function.builtin  @function.method  @keyword  @number
    @operator  @property  @punctuation.special  @string  @type  @variable
