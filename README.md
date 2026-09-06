# SimpleEdit

A small native macOS text editor. Swift + AppKit + `NSDocument`, built with SwiftPM,
wrapped into a `.app` by a shell script. No Electron, no xcodeproj, no xib, no
third-party dependencies.

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
swift test                                          # EditorCore unit tests
go test ./tools/jsonfmt                             # JSON golden tests
```

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
(including the + button and ⇧⌘] switching), typing and undo, line numbers
(including on a 13.9 MB, 400k-line file), ⌘F with Escape returning the caret to the
text, JSON format / minify, the JSON error path reporting the right line and column
on non-ASCII input, the unsaved-changes sheet when closing a dirty tab, and autosave
recovery — an unsaved edit survives `kill -9` while the file on disk stays
byte-identical.

**Not yet verified:**

- Replace-one-by-one and Replace All in the find bar.

**Seen once, not reproduced:** ⌘W closed a tab other than the selected one. It
happened during scripted UI testing, with the intended tab selected and its title
in the title bar, so it may equally have been an artefact of synthesised
keystrokes. Worth watching for; if you can reproduce it by hand, that is a real
bug in how Close routes through the responder chain.

## Roadmap

Planned for the next version, in no particular order.

- **Syntax highlighting** for widely used languages. Which languages is an open
  question and will be decided as it goes — this is a continuous process rather
  than a single release. The likely stack is `tree-sitter` with the first-party
  `swift-tree-sitter` binding, which is what CotEditor 7 ships; that would be this
  project's first third-party dependency, so it is a deliberate decision rather
  than an implementation detail. On the TextKit 2 side the hook is
  `NSTextLayoutManager.renderingAttributesValidator`, pulled during fragment
  layout. Colour has to stay in rendering attributes and out of `NSTextStorage`,
  or it reaches undo, the edited flag and the save path.
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
  encoding menu. Line endings (LF/CRLF/CR) and a UTF-8 BOM are detected on open and
  restored on save.
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
- **Find bar.** Every Find menu item is tagged with an `NSTextFinder.Action` raw
  value and targets First Responder. Replacing the stock bar with a custom one is a
  selector change on those items, with no other menu edits.
