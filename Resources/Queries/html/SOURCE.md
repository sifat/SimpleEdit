# tree-sitter-html queries

`highlights.scm` and `injections.scm` are **byte-for-byte copies** of the
upstream files. Do not edit them.

| | |
| --- | --- |
| Upstream | https://github.com/tree-sitter/tree-sitter-html |
| Tag | v0.23.2 |
| Commit | `5a5ca8551a179998360b4a4ca2c0f366a35acc03` |
| Copied | 2026-09-07 |
| Licence | MIT — see `LICENSE` beside this file |

## Why vendored rather than read from the grammar's own bundle

`tree-sitter-html` ships these queries as a SwiftPM resource bundle, and the
Swift binding this project once used (`LanguageConfiguration(_:name:)`) would
go looking for `TreeSitterHTML_TreeSitterHTML.bundle` inside `Bundle.main`.
That does not suit
this project: the `.app` is assembled by hand in `build.sh`, so the bundle would
have to be copied in by a step whose only failure signal is a missing file at
runtime — no build error, no test failure, just a document that silently refuses
to highlight.

Copying the file into `Resources/Queries/` instead means `build.sh` copies the
whole tree, `swift test` can assert the file exists and still compiles against
the pinned grammar, and adding a language is a new sibling directory with no
build-script change. CotEditor vendors its queries for the same reason.

## The injections query

`injections.scm` marks the body of a `<script>` element as `javascript` and
of a `<style>` element as `css` -- tree-sitter's names, which
`SyntaxLanguage.init?(injectionName:)` maps to this app's languages. It is
what makes inline scripts and stylesheets colour, and the parser is fail-soft
about it: lose the file and every `<script>` body silently goes plain with no
error anywhere, which is why `build.sh` checks that every vendored file
reached the bundle.

## Keeping it in step with upstream

On a grammar version bump, re-copy both files and diff. `QueryContractTests` asserts
the capture-name set is exactly the seven names below, so a query that gains or
loses a capture fails the test suite rather than quietly changing what is
coloured.

    @tag  @tag.error  @constant  @attribute  @string  @comment  @punctuation.bracket

The remapping from these names to this app's own token kinds lives in Swift, in
`SyntaxTokenKind.init?(captureName:)`, so the `.scm` never needs editing.
