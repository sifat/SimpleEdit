# tree-sitter-html queries

`highlights.scm` is a **byte-for-byte copy** of the upstream file. Do not edit it.

| | |
| --- | --- |
| Upstream | https://github.com/tree-sitter/tree-sitter-html |
| Tag | v0.23.2 |
| Commit | `5a5ca8551a179998360b4a4ca2c0f366a35acc03` |
| Copied | 2026-09-07 |
| Licence | MIT — see `LICENSE` beside this file |

## Why vendored rather than read from the grammar's own bundle

`tree-sitter-html` ships these queries as a SwiftPM resource bundle, and
`LanguageConfiguration(_:name:)` will go looking for
`TreeSitterHTML_TreeSitterHTML.bundle` inside `Bundle.main`. That does not suit
this project: the `.app` is assembled by hand in `build.sh`, so the bundle would
have to be copied in by a step whose only failure signal is a missing file at
runtime — no build error, no test failure, just a document that silently refuses
to highlight.

Copying the file into `Resources/Queries/` instead means `build.sh` copies the
whole tree, `swift test` can assert the file exists and still compiles against
the pinned grammar, and adding a language is a new sibling directory with no
build-script change. CotEditor vendors its queries for the same reason.

## Keeping it in step with upstream

On a grammar version bump, re-copy the file and diff. `SyntaxCoreTests` asserts
the capture-name set is exactly the seven names below, so a query that gains or
loses a capture fails the test suite rather than quietly changing what is
coloured.

    @tag  @tag.error  @constant  @attribute  @string  @comment  @punctuation.bracket

The remapping from these names to this app's own token kinds lives in Swift, in
`SyntaxTokenKind.init?(captureName:)`, so the `.scm` never needs editing.
