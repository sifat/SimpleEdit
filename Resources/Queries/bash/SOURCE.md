# tree-sitter-bash queries

`highlights.scm` is a **byte-for-byte copy** of the upstream file. Do not edit it.

| | |
| --- | --- |
| Upstream | https://github.com/tree-sitter/tree-sitter-bash |
| Tag | v0.23.3 |
| Commit | `487734f87fd87118028a65a4599352fa99c9cde8` |
| Copied | 2026-09-11 |
| Licence | MIT — see `LICENSE` beside this file |

The reasoning for vendoring rather than reading the grammar's own resource
bundle is in `../html/SOURCE.md`. The directory is named for the grammar,
`bash`; the language the app shows is `Shell`.

## Why v0.23.3 and not v0.25.1

Not the scanner hazard the other grammars cite. Bash's 0.25 manifests list
`src/scanner.c` unconditionally, so it does not arise here. The reasons are:

- `highlights.scm` is **byte-identical** between v0.23.3 and v0.25.1, so the
  newer tag changes nothing that is coloured.
- v0.25.1's parser is **ABI 15**. Every other grammar in the app is ABI 14.
  tree-sitter 0.25.10 supports both, but it would be a new compatibility surface
  bought for no highlighting difference.
- v0.25.1's manifest declares `swift-tree-sitter` `from: "0.25.0"` — the tag
  that is chronologically older than 0.10.0. It is test-only and SwiftPM prunes
  it, but it is not a thing to invite into the graph.

If a real Bash parse bug turns up that 0.25 fixes, that is the reason to move,
and the byte-identical query makes it a parser-only change.

The external scanner matters: it is what recognises a heredoc, whose body ends
only where its delimiter reappears. `ShellParsingTests` includes a heredoc test
that fails without it.

## Detection

`.sh`, `.bash`, `.zsh`, `.command`, and shell dotfiles **by name** — `.zshrc`,
`.bashrc`, `.bash_profile`, `.profile` and the rest. A dotfile has an empty path
extension, so `SyntaxLanguage.init?(fileName:)` checks known whole names before
falling back to the extension. Without it, the shell files most often opened in
a text editor would all stay plain.

A script with no extension, recognised only by its `#!/bin/bash` line, is not
detected.

## zsh

The grammar is Bash. zsh files parse well enough to colour, but zsh-only syntax
— glob qualifiers, `${(j:,:)array}` flags — becomes error nodes and stays plain,
and error recovery makes zsh cost about three times as much per KB as Bash
(0.37 against 0.10–0.16 ms/KB).

## Predicates

One: `#match? "^-"` on a command's arguments, which is how flags such as `-la`
and `--force` are told apart from ordinary arguments. It is evaluated.

## Captures

All nine map onto existing kinds; no new kind and no override is needed except
one, written out on purpose:

| Capture | Treatment |
| --- | --- |
| `@embedded` | **unmapped** — covers a whole `$(…)`, `<(…)` or `${…}` including the command inside, which outermost-wins would swallow. Already the default; explicit so a future shared row cannot reach it. |
| `@number` | a file descriptor, the `2` in `2>&1` → constant |
| `@operator` | `$ && > >> < \|` → punctuation |
| `@property` | a variable name |

## Keeping it in step with upstream

On a version bump, re-copy the file and diff. `QueryContractTests` asserts the
capture-name set is exactly the nine names below.

    @comment  @constant  @embedded  @function  @keyword  @number  @operator
    @property  @string
