# SimpleEdit

A small native macOS text editor. Swift + AppKit + `NSDocument`, built with SwiftPM,
wrapped into a `.app` by a shell script. No Electron, no xcodeproj, no xib.

Ten third-party dependencies, all pinned, all for syntax
highlighting, and **all of them C**:
[`tree-sitter`](https://github.com/tree-sitter/tree-sitter) itself plus the
[HTML](https://github.com/tree-sitter/tree-sitter-html),
[CSS](https://github.com/tree-sitter/tree-sitter-css),
[JavaScript](https://github.com/tree-sitter/tree-sitter-javascript),
[TypeScript](https://github.com/tree-sitter/tree-sitter-typescript),
[Python](https://github.com/tree-sitter/tree-sitter-python),
[Bash](https://github.com/tree-sitter/tree-sitter-bash),
[Java](https://github.com/tree-sitter/tree-sitter-java),
[PHP](https://github.com/tree-sitter/tree-sitter-php) and
[SQL](https://github.com/DerekStride/tree-sitter-sql) grammars. There is
no Swift binding in between — the query loop talks to the C API directly, because the
binding allocated an object per capture and that was most of the cost of highlighting.
Each grammar's highlight query is vendored into `Resources/Queries/` under its MIT
licence — see the `SOURCE.md` beside it for why, and for how to keep it in step with
upstream.

If you have come to macOS from Linux and miss **gedit** — a plain editor that opens
instantly, edits a file, and gets out of the way — this is that, built the way a Mac
app should be: real menus, real tabs, real save panels, no bundled browser.

One Go helper binary ships inside the bundle and does the JSON formatting — see
[The Go helper](#the-go-helper).

## Install

Grab `SimpleEdit.zip` from the [latest release](https://github.com/sifat/SimpleEdit/releases/latest), then:

```sh
unzip SimpleEdit.zip
mv SimpleEdit.app /Applications/
xattr -dr com.apple.quarantine /Applications/SimpleEdit.app
open /Applications/SimpleEdit.app
```

**The `xattr` line is required.** The app is ad-hoc signed rather than signed with
a paid Apple Developer ID, so macOS quarantines it on download and reports
*"SimpleEdit is damaged and can't be opened"*. That message means "not signed by a
registered developer", not "corrupted" — and right-click ▸ Open does not get past
it on macOS 15+.

The download is a universal binary, so it runs on both Apple Silicon and Intel Macs.

## Cutting a release

```sh
./build.sh --universal --zip     # -> build/SimpleEdit.zip
```

Then create the release and attach the zip — either through the web UI
(repo ▸ Releases ▸ Draft a new release) or with the API:

```sh
gh release create v1.1 build/SimpleEdit.zip --title "SimpleEdit 1.1" --notes-file NOTES.md
```

Always use `--universal`; a default build is arm64-only and will not launch on an
Intel Mac. Put the `xattr` instruction in the release notes, or the first thing
anyone downloading it will hit is "damaged".

## Build and run

```sh
./build.sh                                          # -> build/SimpleEdit.app
open build/SimpleEdit.app
```

Then drag `build/SimpleEdit.app` to `/Applications`.

```sh
swift test                                          # EditorCore + SyntaxCore unit tests
go test ./tools/jsonfmt                             # JSON golden tests
```

`Package.resolved` is committed deliberately: it is the only record of which
grammar commit a given build shipped. The first build is slow rather than the
resolve: `tree-sitter-sql`'s generated `parser.c` is 41.6 MB, and a universal
build compiles it twice.

### Debugging

`open` detaches the process, so `print()` output goes to the unified log. Either
launch the inner binary directly (still a fully bundled launch, since
`Bundle.main` resolves from the executable's location):

```sh
./build/SimpleEdit.app/Contents/MacOS/SimpleEdit
```

or read the log:

```sh
log stream --style compact --predicate 'process == "SimpleEdit"'
```

`swift run` is useless here: without the bundle there is no `CFBundleDocumentTypes`,
so `NSDocumentController.defaultType` is nil and ⌘N fails silently.

After changing `CFBundleDocumentTypes`, re-register or Finder keeps the stale
association:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f build/SimpleEdit.app
```

## App icon

`Resources/AppIcon.icns` is generated, not hand-drawn, so it can be edited as code:

```sh
xcrun swift tools/appicon/make-icon.swift
```

That renders every size the iconset needs (16 through 512@2x), each drawn at its
real pixel size rather than downsampled from the 1024 artwork, and runs
`iconutil`. `build.sh` copies the result into `Contents/Resources`, and
`CFBundleIconFile` in Info.plist points at it. After changing the icon, re-register
the bundle or Finder keeps showing the old one:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f build/SimpleEdit.app
```

## Architectures

`./build.sh` alone builds arm64 only, which is right for working on this machine.
`--universal` produces an `x86_64 arm64` binary so it also runs on Intel Macs, and
`--zip` packages the result with `ditto` (which preserves the bundle signature;
plain `zip` does not). Verify the architectures with:

```sh
lipo -archs build/SimpleEdit.app/Contents/MacOS/SimpleEdit
```

## Shortcuts

| | |
| --- | --- |
| New / Open / Save | ⌘N · ⌘O · ⌘S |
| Save As / Close | ⇧⌘S · ⌘W |
| Undo / Redo | ⌘Z · ⇧⌘Z |
| Find | ⌘F |
| Find Next / Previous | ⌘G · ⇧⌘G |
| Find and Replace | ⌥⌘F |
| Use Selection for Find | ⌘E |
| Format JSON | ⌃⌘J |
| Minify JSON | ⇧⌃⌘J |
| Line Numbers | ⌃⌘L |
| Wrap Lines | ⌥⌘W |
| Appearance | View ▸ Appearance ▸ System / Light / Dark |
| Page Setup / Print | ⇧⌘P · ⌘P |
| Export as PDF | File ▸ Export as PDF… |
| Next / Previous tab | ⌃⇥ · ⌃⇧⇥ (also ⇧⌘] · ⇧⌘[) |
| Enter / Exit Full Screen | ⌃⌘F |
| Minimize / Zoom | ⌘M · Window ▸ Zoom (or double-click the title bar) |

Find and Replace lives in the standard AppKit find bar: the ‹ › buttons step
matches, and the Replace disclosure reveals a `Replace` button (one at a time) and
`All`. The bar has no match counter — AppKit does not ship one.

## Syntax highlighting

**HTML** (`.html`, `.htm`), **CSS** (`.css`), **JavaScript** (`.js`, `.mjs`, `.cjs`),
**TypeScript** (`.ts`, `.mts`, `.cts`), **Python** (`.py`, `.pyi`, `.pyw`),
**Shell** (`.sh`, `.bash`, `.zsh`, `.command`, and dotfiles such as `.zshrc` and
`.bashrc`), **Java** (`.java`), **PHP** (`.php`, `.phtml`) and **SQL** (`.sql`) are
coloured. Nothing else is, and nothing needs turning on: the language
is detected from the file name when the document opens — a known dotfile name first,
then the extension.

Inside an HTML page, `<style>` and `<script>` bodies are coloured as CSS and
JavaScript. The HTML grammar hands those over as one opaque node, so each is
re-parsed with its own grammar and the results are merged back into the document's
own offsets.

A PHP file is two documents interleaved, and it is coloured as both. The text
outside `<?php … ?>` is HTML, and it is handed to the HTML grammar as **one
combined document** rather than as a series of fragments: a template opens a
`<div>` above a `<?php` and closes it below the matching `?>`, so parsing each
fragment separately would report unbalanced tags that are not in the file.
tree-sitter is instead given every fragment's range at once and lexes them as one
continuous stream, skipping the PHP. Measured over 381 WordPress templates, that
is the difference between 521 error nodes and 126. The HTML then injects its own
`<style>` and `<script>`, so a template nests three languages deep — the only
place in the app that goes past one. Tokens from an inner language are cut back
to its own ranges, which is what stops one HTML attribute value from swallowing
the PHP echoed inside it.

The parse is **incremental**. The highlighter is the text storage's delegate, and
every character edit — typing, paste, undo, Replace All — is reported to tree-sitter
as it happens, so the next parse re-lexes only around the edits and reuses every
subtree they did not touch. Measured in release, that halves the cost of a keystroke
on every ordinary file tested; the other half is the highlights query, which still
walks the whole tree. The contract, pinned by a randomised differential test: on text
that parses cleanly the tokens are identical to a fresh parse; on text with syntax
errors they may differ, because tree-sitter may recover differently when reusing a
tree than when starting cold; and once the error is fixed they agree again.

Colour is delivered through `NSTextLayoutManager.renderingAttributesValidator` —
TextKit 2 asks for a fragment's colours as it lays that fragment out — and never by
mutating `NSTextStorage`. That is the whole design constraint: colour cannot reach
undo, the edited flag or the save path, so a highlighted document saves
byte-identical and closing it asks nothing. Why that particular API, and the
measurements behind it, are in [Escape hatches](#escape-hatches).

| | |
| --- | --- |
| Tags, selectors, property and method names | blue |
| Attributes, pseudo-classes | purple |
| Type names | purple |
| Strings, hex colours, regex literals | red |
| Comments | green |
| Numbers, units, the doctype, `true`/`null` | teal |
| Keywords, at-rules, `!important` | pink |
| Functions | indigo |
| Brackets, operators, delimiters | grey |
| Mismatched closing tag | orange |

Plain identifiers are **not** coloured, in any language — variables, parameters, and
in JavaScript and Python class names too. Java is the exception for class names: its
grammar knows a type from where it appears, so they are coloured there. That is a deliberate consequence of how overlapping
captures are resolved, and `Resources/Queries/javascript/SOURCE.md` explains it: the
grammar captures every identifier, and that capture collides with several others over
the same range, so colouring it would make the winner a sort tie-break rather than a
decision. In TypeScript, capitalised names *are* coloured, because there the type
grammar genuinely knows they are types.

They are system colours, so Dark mode, Increase Contrast and appearance switching
all work with no code — see the spike notes for why that comes free.

Adding a language is an enum case in `SyntaxLanguage`, a directory under
`Resources/Queries/`, one package dependency, and its capture names in
`SyntaxTokenKind`. Capture names are interpreted **per language**, because grammars
reuse the same name for different things: `@variable` is a CSS custom property and
any identifier at all in JavaScript, and `@type` is the `px` in CSS's `10px` and a
type name in TypeScript. `build.sh` copies the whole queries tree, so it needs no change.
The vendored `.scm` files are **byte-for-byte copies of upstream and must not be
edited** — remapping happens in Swift, which is what keeps a version bump a plain
diff. `swift test` pins each query's capture set, so a grammar bump that renames a
capture fails the suite instead of silently un-colouring something.

### What it does not do

- **Large files are not highlighted at all** — above 128 KB for CSS, above 64 KB
  for everything else. Tokenising is synchronous on the edit path, so its cost is
  paid per keystroke. Measured in release, which is what ships:

  | | |
  | --- | --- |
  | Java, JDK and Android sources | 0.07–0.14 ms/KB |
  | JavaScript, library code | 0.07 ms/KB |
  | Shell, real bash scripts | 0.10–0.16 ms/KB |
  | CSS, real stylesheets | 0.12 ms/KB |
  | PHP, WordPress templates | 0.13–0.21 ms/KB |
  | Python, standard library | 0.14–0.20 ms/KB |
  | HTML, markup with inline JavaScript | 0.21 ms/KB |
  | JavaScript, dense component code | 0.21 ms/KB |
  | SQL, hand-written, dense | 0.22 ms/KB |
  | TypeScript, dense | 0.22 ms/KB |
  | HTML, tag-dense markup | 0.26 ms/KB |
  | Java, dense streams and lambdas | 0.32 ms/KB |
  | Shell, zsh-specific syntax | 0.37 ms/KB |
  | Shell, dense bash | 0.38 ms/KB |
  | PHP, dense template, markup and code both | 0.42 ms/KB |
  | Python, dense comprehensions | 0.49 ms/KB |
  | SQL, a mysqldump file near its cap | 0.25–0.81 ms/KB |

  Every rate is a fresh full parse and query, release build, on an Apple Silicon
  laptop; this table is the only home for these numbers. The per-keystroke cost
  with the incremental parse is lower — about half, on ordinary files.
  | Python, dense comprehensions | 0.49 ms/KB |

  A 64 KB file of the densest markup is about 17 ms here. The cap is sized so that
  a typical file at the cap stays well inside the time budget below on slower
  hardware. Python is the awkward case: real Python is cheap and real Python files
  are often large, but dense Python is the most expensive code measured in any
  language, so it keeps the 64 KB cap and big standard-library modules stay plain.
  Java makes the same trade: large JDK files such as `HashMap.java` stay plain.
  PHP keeps the same cap for a different reason: it pays for two grammars on every
  keystroke, its own and the HTML around it, and a 64 KB template of dense markup
  and dense code costs about 27 ms for a full parse (29 ms per keystroke, median,
  with the incremental reuse) — just under dense Python, which set this bar. Real
  templates are far cheaper: WordPress's 62 KB `media-template.php` is 12 ms
  (14 ms per keystroke).
  **SQL caps at 32 KB**, half of everything else, and it is the one language whose
  cap is set by broken files rather than dense ones. Dense hand-written SQL is
  cheap — 64 KB of it is 14 ms — but the `.sql` files that exist on disk are
  database dumps, which this grammar cannot parse, and error recovery over a
  single enormous `INSERT` costs superlinearly: on a real dump, 7.8 ms at 32 KB,
  16 ms at 48 KB, 52 ms at 64 KB.
- **A hostile or half-typed file is left plain, not frozen on.** The size cap
  cannot bound the worst case, because the worst case is nesting depth and
  unbalanced brackets — quadratic, and reachable from an ordinary file mid-edit:
  unbounded, 64 KB of unclosed `<b>` costs 1.6 s per keystroke, 128 KB of nested
  `:is(` costs 11.5 s, and 64,000 unclosed parens cost 3.9 s. So each parse and
  each query runs under an **80 ms budget**; when it runs out the document is left
  plain, not partially coloured, and colour returns on the next keystroke once the
  text is parseable again. Measured, every one of those cases now lands at
  80–96 ms. The incremental parse cannot help a document that is cut, because a
  document that has never parsed inside the budget has no tree to reuse — so after
  a cut, attempts are spaced out instead: the next keystroke is skipped, then three,
  then seven, and from there one keystroke in eight is tried. A hostile document
  costs about a tenth of the budget per keystroke rather than all of it, and colour
  returns within eight keystrokes of the text becoming parseable again.
- **A large inline `<script>` or `<style>` is re-parsed in full on every keystroke.**
  The document's own parse is incremental; the embedded languages are parsed from
  their substring each time, because that substring moves and changes wholesale with
  every edit around it. A page whose bulk is one big inline script gains little from
  the incremental parse (measured 1.1× against 2× for everything else).
- **Only the HTML inside a PHP file is injected.** Upstream's PHP grammar can also
  inject phpdoc into comments and name a heredoc's language after its terminator
  (`<<<SQL`); neither grammar is vendored, so `/** … */` colours as a plain comment
  and a heredoc body as a plain string. Drupal's `.module`, `.inc`, `.install` and
  `.theme` are PHP too but are not claimed, because `.inc` is not PHP anywhere else.
- **A few valid PHP names are parsed as errors.** The pinned grammar adopted PHP's
  reserved-word rules, which reject `const FALSE` (and `TRUE`, `MIXED`, `ITERABLE`,
  `VOID`), keyword properties inside double-quoted strings such as `"$obj->class"`,
  and a global `function readonly()`. Across 45,818 files of WordPress and Drupal
  that is 5 files, losing 8–29 characters of colour each. The alternative was the
  newest grammar that predates the change, which cannot parse an enum containing a
  `const` at all — 6 of 6 such files in a real Drupal tree, up to a quarter of a
  file uncoloured. `Resources/Queries/php/SOURCE.md` has the measurements.
- **A mysqldump or phpMyAdmin export is barely highlighted.** The only SQL
  grammar available leans ANSI and PostgreSQL. Hand-written SQL parses cleanly,
  but MySQL's versioned comments (`/*!40101 SET … */`), `START TRANSACTION`,
  `COLLATE` in a column definition, `ENGINE=InnoDB` table options and
  `LOCK TABLES` do not: of 25 real dumps tested, 24 contained parse errors, and
  one 268 KB phpMyAdmin export parsed as a single error node end to end. Most
  dumps are far past the size cap and stay plain anyway. There is no MySQL
  grammar to switch to — the alternatives target PostgreSQL and SQLite — and the
  measurements are in `Resources/Queries/sql/SOURCE.md`.
- **SQL is most of the app's size.** Its parse tables are 11.2 MB per
  architecture against 1.5 MB for the next largest grammar, because one grammar
  covers several dialects at once. The universal binary went from about 12 MB to
  34 MB when it was added. That is the cost of the language, and it was taken
  knowingly.
- **A shell script with no extension is not detected.** Dotfiles are recognised by
  name, but a script recognisable only by its `#!/bin/bash` line stays plain. zsh
  files colour less completely than Bash, because the grammar is Bash and zsh-only
  syntax parses as errors.
- **Minified files are not highlighted**, on the signal the editor already has: if a
  file's longest line forced wrapping off, one layout fragment covers the whole
  document and the validator would be handed every token in it at once.
- **`.jsx` and `.tsx` are not claimed.** Both need a second JSX query file that is
  not vendored, and claiming them without it would colour JSX markup as ordinary
  expressions.
- **A locally shadowed builtin is still coloured as a builtin** in JavaScript. The
  query asks for `#is-not? local`, which needs `locals.scm` and a scope resolver;
  neither is loaded, so the predicate always passes.
- **There is no language override menu.** Detection is by extension only, so a
  stylesheet saved as `.txt` stays plain. This is not an oversight — changing the
  language of an open document cannot repaint it, for the reason recorded under
  [Escape hatches](#escape-hatches): colour cannot be refreshed when the text itself
  has not changed.
- **Printing is black.** The print view is a separate TextKit 1 view with no
  highlighter attached.

## The Go helper

`tools/jsonfmt` is ~100 lines of Go with no dependencies, built into
`SimpleEdit.app/Contents/MacOS/jsonfmt`. It is independently runnable:

```sh
echo '{"z":1,"a":1.0}' | ./build/SimpleEdit.app/Contents/MacOS/jsonfmt pretty
```

It exists because **Foundation cannot pretty-print JSON without damaging it**.
`JSONSerialization` parses into an unordered `NSDictionary`, which destroys object
key order before any writing option applies, and re-renders numbers from their
binary value (`1.0` → `1`, `1e2` → `100`). `.sortedKeys` only gives alphabetical
order. There is no order-preserving JSON value type anywhere in the macOS SDK.

Go's `encoding/json.Indent` is a byte-level re-emitter rather than a
decode-then-encode round trip, so key order, duplicate keys, number literals and
string escapes all survive byte-identically.

Two things worth knowing if you touch this code:

- `json.Indent` and `json.Compact` return `*json.SyntaxError` with **`Offset`
  always 0** — only the `Unmarshal`/`Decoder` path populates it. `locate()`
  re-parses with `Unmarshal` purely to find the error position; its decoded value
  is thrown away, so the verbatim guarantee of the output path is untouched.
- The offset is a **UTF-8 byte** offset, but `NSTextView` ranges are **UTF-16 code
  units**. `EditorCore.SourceLocationMapper` converts. Skipping that does not just
  misplace the caret — on a document with CJK or emoji before the error, the byte
  offset can exceed the string length and throw `NSRangeException`.

## Known issues

Nothing is currently known to be broken in normal use. What follows is an honest
list of what has and has not been exercised end to end.

**Verified working:** opening and saving files, arbitrary file extensions, tabs
(including the + button and ⇧⌘] switching), typing and undo, line numbers (including
on a 13.9 MB, 400k-line file), ⌘F with Escape returning the caret to the text,
Replace and Replace All (with Replace All undoing as a single step), JSON format /
minify, the JSON error path reporting the right line and column on non-ASCII input,
the unsaved-changes sheet when closing a dirty tab, dark mode and the appearance
toggle, printing (5 correctly paginated pages from a 122-line file, verified through
PDF export), and autosave recovery — an unsaved edit survives `kill -9` while the
file on disk stays byte-identical.

Syntax highlighting was checked the same way, in a running app rather than only
under test: every language on real files, a single page carrying inline
`<style>` and `<script>` with three grammars colouring at once, colour following
live typing, Dark mode re-resolving every colour with no code involved, a saved file
byte-identical to what was typed, and opening then closing a highlighted document
raising no unsaved-changes sheet — the last two being the properties the whole
rendering-attributes design exists to protect. The time budget was checked the same
way: a 49 KB page that the original 32 KB cap excluded is coloured, and 64 KB of unclosed `<b>`
— 1.6 s per keystroke unbounded — opens plain, takes typing, and the app stays
responsive.

**Seen once, not reproduced:** ⌘W closed a tab other than the selected one. It
happened during scripted UI testing, with the intended tab selected and its title
in the title bar, so it may equally have been an artefact of synthesised
keystrokes. Worth watching for; if you can reproduce it by hand, that is a real
bug in how Close routes through the responder chain.

## Roadmap

Planned for the next version, in no particular order.

- **The language list is done for now.** HTML, CSS, JavaScript, TypeScript,
  Python, Shell, Java, PHP and SQL all ship. Another would be an enum case, a
  vendored query directory and a package dependency — see
  [Syntax highlighting](#syntax-highlighting).
- **Incremental highlighting query.** The parse is incremental now, but the
  highlights query still walks the whole tree on every keystroke, and on an
  ordinary file that is the remaining half of the cost. `ts_tree_get_changed_ranges`
  gives the byte ranges whose structure changed; re-querying only those and shifting
  the rest of the previous token list would make the whole keystroke proportional to
  the edit. The subtlety to design around is that a capture's match can depend on
  its ancestors, so the changed ranges must be trusted to cover every node whose
  match status could have changed — which is what they are documented to do.

Nothing else is planned for the next release.

## Notes and limitations

- **Tabs always.** `tabbingMode = .preferred` deliberately overrides System
  Settings, including an explicit "Prefer tabs: Never".
- **Saving replaces symlinks.** `NSDocument`'s safe-save writes a temp file and
  swaps it in, so editing a symlinked dotfile (say `~/.zshrc` pointing into a
  dotfiles repo) replaces the symlink with a regular file.
- **Line numbers stop above 64 MB.** Past that the gutter draws an empty strip
  rather than a wrong number. Reading and scrolling a file of any size costs
  nothing, since the index is only rebuilt after an edit; typing into one that
  large still pays a rescan per frame, which is what an incremental index would
  fix if it ever becomes worth doing.
- **Encoding detection is a guess** when a file is not UTF-8, and there is no
  encoding menu. A character the detected encoding cannot hold makes the file
  UTF-8 on the next save, and it stays UTF-8 from then on; nothing tells you.
  Line endings (LF/CRLF/CR) and a UTF-8 BOM are detected on open and restored on
  save — but a file whose endings are **mixed** is rewritten wholesale to
  whichever kind appears first, on lines you never touched, the first time it is
  saved.
- **Printing reflows for the paper.** Print builds a throwaway text view sized to
  the page rather than printing the one on screen, so the line-number gutter does
  not appear on paper and a document with wrapping turned off does not print as one
  absurdly wide page. It sets 10pt rather than the editor's 13pt, which is what lets
  a normal 80-column line fit the width. There are no page headers or footers yet.
- **Appearance is app-wide, not per-window.** View ▸ Appearance sets
  `NSApp.appearance`, so every tab and every window opened later follows it. The
  choice is stored in `UserDefaults`; an absent key means System, so a fresh
  install follows the system setting exactly as it always did. In Dark Aqua the
  gutter and the text background are nearly the same shade — that is
  `controlBackgroundColor` and `textBackgroundColor` converging, and the hairline
  separator is what distinguishes them.
- **Autosave writes recovery copies, never your file.** Every 30 seconds an edited
  document is written to `~/Library/Autosave Information/`. The file you opened is
  only ever written when you save it, so pointing the editor at `~/.zshrc` to read
  it cannot rewrite it behind your back, and the unsaved-changes sheet on close
  still appears. After a crash macOS reopens the recovered copy. It can also open
  the same file twice — once from saved window state, once from the autosave record
  — which the app reconciles at launch, keeping whichever copy holds unsaved work.
- **Untitled tabs may not come back.** Reopening on relaunch tracks file URLs, so
  unsaved new tabs have nothing to restore from. Autosave may now cover some of
  this, since `autosavesDrafts` defaults to on, but that path is untested.
- **Rebuilds look like a new app to TCC.** The ad-hoc signature has no stable
  identity, so granted Files & Folders permissions do not persist across builds. If
  a copy picks up a quarantine flag (AirDrop, a downloaded zip) and macOS calls it
  damaged: `xattr -dr com.apple.quarantine SimpleEdit.app && codesign --force --sign - SimpleEdit.app`.
- `spctl -a -vv` reports rejection for an ad-hoc signature. That is expected and
  does not prevent launch — Gatekeeper only gates quarantined files.

## Escape hatches

- **TextKit.** `EditorViewController.loadView()` builds the text view with
  `NSTextView(usingTextLayoutManager: true)` (TextKit 2). Flip to `false` for
  TextKit 1 if a custom find bar with highlight-all is ever needed
  (`addTemporaryAttribute` is TextKit 1 only) — that also means switching
  `LineNumberRulerView` to `NSLayoutManager.enumerateLineFragments`.
- **TextKit 2 rendering attributes work, but only if you never invalidate them.**
  Syntax highlighting colours text through
  `NSTextLayoutManager.renderingAttributesValidator` rather than by mutating
  `NSTextStorage`, so colour never reaches undo, the edited flag or the save path.
  That approach has a bad public reputation — Apple DTS confirmed on Developer
  Forums thread 817471 that `addRenderingAttribute` plus `invalidateLayout` stores
  attributes without repainting, FB9692714 has been open since 2022, and STTextView
  abandoned the API — so it was measured before being adopted. Findings, from a
  throwaway spike on a 200-line file:

  - The validator fires reliably. Colour is present on first paint with no
    keystroke, scroll or resize, and after an edit **every affected fragment
    re-validates, including ones far below the edit**. 147 validator calls on open,
    about 5 for a local edit.
  - **`invalidateRenderingAttributes(for:)` destroys colour and never asks for it
    back.** The header says enumeration "will skip the invalidated range", and that
    is exactly what happens — call it and the text goes black, permanently, through
    edits and even a window resize. Every escalation built on it made things worse
    than doing nothing. This is very likely what the public reports are actually
    hitting: the instinct is to invalidate, and invalidating is the bug.
  - So the rule is: **set attributes from the validator, and never invalidate
    them.** Let re-layout drop them and re-ask.
  - Dynamic `NSColor`s resolve at draw time inside rendering attributes, so an
    appearance change recolours correctly with no invalidation and no observer.
    Semantic and `system*` colours are therefore free.
  - The validator runs on the main thread, synchronously during layout, at 5–11 µs
    mean and 60 µs worst case per fragment. It must stay a pure lookup: no parsing,
    no `ensureLayout`, no `needsDisplay`.
  - Saving a coloured document produces a byte-identical file.

  What is *not* solved: changing the colour of already-laid-out text when the text
  itself has not changed. Neither doing nothing nor `invalidateLayout` repaints it.
  Appearance switching is unaffected, since dynamic colours handle that at draw
  time, but two things do depend on it: user-selectable themes, and a View ▸ Syntax
  menu that could change an open document's language. Both are blocked on the same
  question. The untried candidate is a `performEditingTransaction` around
  `textStorage.edited(.editedAttributes, range:, changeInLength: 0)`, which would
  have to be shown not to set the edited flag or register undo before it could be
  used for anything.

- **Find bar.** Every Find menu item is tagged with an `NSTextFinder.Action` raw
  value and targets First Responder. Replacing the stock bar with a custom one is a
  selector change on those items, with no other menu edits.
