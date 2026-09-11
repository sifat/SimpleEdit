# tree-sitter-typescript queries

`highlights.scm` is a **byte-for-byte copy** of the upstream file. Do not edit it.

| | |
| --- | --- |
| Upstream | https://github.com/tree-sitter/tree-sitter-typescript |
| Tag | v0.23.2 |
| Commit | `f975a621f4e7f532fe322e13c4f79495e0a7b2e7` |
| Copied | 2026-09-07 |
| Licence | MIT — see `LICENSE` beside this file |

The reasoning for vendoring rather than reading the grammar's own resource
bundle is in `../html/SOURCE.md`.

There is no v0.24 or v0.25 tag on this repo, so the relative-path scanner hazard
described in `../css/SOURCE.md` does not arise here — v0.23.2 is simply the
newest tag, and both of its targets list `scanner.c` unconditionally.

## This file is a FRAGMENT and is not usable on its own

35 lines: type identifiers, predefined types, type arguments, parameters, and
fifteen TypeScript-only keywords. **No strings, comments, numbers, operators,
brackets, or any JavaScript keyword.** Upstream states the composition itself,
in this repo's own `tree-sitter.json`:

    "name": "typescript",
    "highlights": [
      "queries/highlights.scm",
      "node_modules/tree-sitter-javascript/queries/highlights.scm"
    ]

An ordered list, this fragment first. `SyntaxLanguage.queryFiles` reproduces
exactly that order, and `SyntaxParser` concatenates the files at load time.

Loading the fragment alone is not a reduced-fidelity option. It colours type
names and the word `interface` and nothing else — a few per cent of a real file
— and it does so **silently**: the query compiles, the parser runs, nothing
errors. The result looks broken rather than deliberately plain, which is the
exact failure mode `../html/SOURCE.md` says vendoring exists to avoid.
`TypeScriptParsingTests` guards both halves: one test fails if JavaScript's file
stops being loaded, another if this one does.

## The second file

The JavaScript half is **not duplicated here**. It is
`../javascript/highlights.scm`, vendored under its own directory with its own
tag and its own LICENSE, because that is the path matching its own upstream
repo. A concatenated blob checked in as one file was rejected: it would match no
upstream URL, so "re-copy the file and diff" — the instruction in every
SOURCE.md here — would stop being true, and a bump moving one half would be
indistinguishable from a bump moving the other.

The two pins are **not independent**. This repo's `package.json` requires
`tree-sitter-javascript ^0.23.1`, so the JavaScript query is expected to match
the JavaScript pin, and the two should be bumped together.

## Captures this app does not colour

TypeScript inherits JavaScript's three unmapped captures — `@variable`,
`@constructor`, `@embedded`, all explained in `../javascript/SOURCE.md` — and
adds `@variable.parameter`, which falls back to `@variable` and so is unmapped
by the same rule. Parameter names therefore stay plain while their type
annotations are coloured.

`@type` is the one capture name that means something genuinely different in two
of the vendored grammars. In CSS it is the `px` in `10px`, which maps to
`constant` so that a number and its unit colour as one thing. In TypeScript it
is a type *name*. `SyntaxTokenKind.overrides` scopes it per language.

Because TypeScript maps `@type` and leaves `@constructor` unmapped, a
capitalised identifier — captured as both, over the same range — resolves to the
type colour. So `new HttpError()` is coloured in a `.ts` file and plain in a
`.js` one. That is not an inconsistency: only the TypeScript grammar knows it is
a type.

## What is not claimed

`.tsx`. The product also builds a `tsx` grammar and exposes
`tree_sitter_tsx()`, but TSX needs a **three**-file query — this fragment, then
`highlights-jsx.scm`, then JavaScript's — and that JSX file is not vendored.
Claiming `.tsx` without it would highlight JSX markup as ordinary expressions.

## Keeping it in step with upstream

On a version bump, re-copy the file and diff. `QueryContractTests` asserts the
composed capture-name set is exactly the twenty-two names below — JavaScript's
nineteen plus three. If it ever equals JavaScript's nineteen exactly, the
concatenation has silently stopped happening.

    @comment  @constant  @constant.builtin  @constructor  @embedded  @function
    @function.builtin  @function.method  @keyword  @number  @operator  @property
    @punctuation.bracket  @punctuation.delimiter  @punctuation.special  @string
    @string.special  @type  @type.builtin  @variable  @variable.builtin
    @variable.parameter
