# SimpleEdit

A small native macOS text editor. Swift + AppKit + `NSDocument`, built with SwiftPM,
wrapped into a `.app` by a shell script. No Electron, no xcodeproj, no xib, no
third-party dependencies.

One Go helper binary ships inside the bundle and does the JSON formatting — see
[The Go helper](#the-go-helper).

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

## Sharing it with other people

The app is **ad-hoc signed** — there is no Apple Developer ID on this machine
(`security find-identity -v -p codesigning` reports 0 identities). That is fine
locally, because Gatekeeper only inspects files carrying the
`com.apple.quarantine` flag and a local build never has one. It is *not* fine the
moment the app travels: AirDrop, a downloaded zip, Slack and email all set that
flag, and macOS then refuses to open it.

Pick the option that matches who you are sending it to.

### 1. Send them the source (simplest, no Gatekeeper problem)

Push this repo and let them build it:

```sh
git clone <your-repo-url> && cd very-simple-text-editor
./build.sh && open build/SimpleEdit.app
```

They need Xcode (or the Command Line Tools) and Go. Nothing is signed, nothing is
blocked, and they can read what they are running.

### 2. Send them the .app (works, but they must clear the quarantine flag)

```sh
./build.sh --universal --zip     # -> build/SimpleEdit.zip, arm64 + Intel, ~1.8 MB
```

Send `build/SimpleEdit.zip`. On their machine:

```sh
unzip SimpleEdit.zip
mv SimpleEdit.app /Applications/
xattr -dr com.apple.quarantine /Applications/SimpleEdit.app
open /Applications/SimpleEdit.app
```

Without that `xattr` line macOS reports *"SimpleEdit is damaged and can't be
opened"* — which is Gatekeeper's message for a quarantined ad-hoc signature, not
an actual corrupted download. Right-clicking ▸ Open does **not** get past it, and
on macOS 15+ the old bypass is gone. This is fine for colleagues you can send a
command to; it is not something to hand a non-technical person.

### 3. Sign and notarize it (the only version that "just works")

Needs the Apple Developer Program ($99/year) and a Developer ID Application
certificate. Then, instead of the ad-hoc step in `build.sh`:

```sh
codesign --force --options runtime --timestamp \
    --sign "Developer ID Application: YOUR NAME (TEAMID)" \
    build/SimpleEdit.app/Contents/MacOS/jsonfmt
codesign --force --options runtime --timestamp \
    --sign "Developer ID Application: YOUR NAME (TEAMID)" \
    build/SimpleEdit.app

ditto -c -k --keepParent build/SimpleEdit.app build/SimpleEdit.zip
xcrun notarytool submit build/SimpleEdit.zip \
    --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD \
    --wait
xcrun stapler staple build/SimpleEdit.app
```

Note the differences from the local build: `--options runtime` (hardened runtime,
required for notarization) and `--timestamp`. Staple the `.app`, then re-zip it
for distribution. After that it opens anywhere with no warning and no terminal
commands.

### App icon

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

### Architectures

`./build.sh` alone builds arm64 only, which is right for working on this machine.
Use `--universal` for anything you send to someone else — it produces an
`x86_64 arm64` binary, so it runs on Intel Macs too. Verify with:

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
| Next / Previous tab | ⌃⇥ · ⌃⇧⇥ (also ⇧⌘] · ⇧⌘[) |
| Enter / Exit Full Screen | ⌃⌘F |
| Minimize / Zoom | ⌘M · Window ▸ Zoom (or double-click the title bar) |

Find and Replace lives in the standard AppKit find bar: the ‹ › buttons step
matches, and the Replace disclosure reveals a `Replace` button (one at a time) and
`All`. The bar has no match counter — AppKit does not ship one.

## The Go helper

`tools/jsonfmt` is ~30 lines of Go with no dependencies, built into
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

## Five bugs that only showed up at runtime

Recorded because each is invisible to the compiler, silent at launch, and the
kind of thing that costs an afternoon.

1. **`@main` on an `NSApplicationDelegate` does not wire up the delegate.** It
   compiles and the app launches, because AppKit supplies
   `static func main() { exit(NSApplicationMain(...)) }`. But `NSApplicationMain`
   only ever *discovers* a delegate by loading the main nib, and there is no nib
   here — so `NSApp.delegate` stayed nil and the app was a live run loop with no
   menu bar, no document and no window. Fixed by building the application object
   explicitly in `AppMain.swift`.
2. **`NSTextView(usingTextLayoutManager:)` starts at `NSZeroRect`.** The header
   says so outright. A 0×0 text view sits in the hierarchy looking fine and cannot
   be clicked into or typed in.
3. **Assigning `contentViewController` resizes the window to the view's fitting
   size.** An `NSScrollView` has no intrinsic content size, so the window
   collapsed to `minSize` — *after* any frame set on it. Size the window after the
   content view controller is in place, not before.
4. **Never change `ruleThickness` inside `drawHashMarksAndLabels`.** It invalidates
   the enclosing scroll view's layout, and doing that mid-draw puts NSScrollView
   into a tile/draw loop that never settles: the gutter paints, the text never
   does. The line index and gutter width are now recomputed on the text-change
   path instead.
5. **`NSRulerView` hands `drawHashMarksAndLabels(in:)` a rect that is not clipped
   to the ruler.** Measured here: a 900pt-wide rect against a 24.8pt ruler. Filling
   it paints an opaque rectangle straight over the document and the text silently
   disappears. Always intersect with `bounds` first.
6. **`preferredContentSize` on the content view controller pins the window.** It
   was added while chasing bug 3 and silently made the window non-resizable and
   un-zoomable. The ordering fix in `EditorWindowController` is the real
   correction; the size hint was both redundant and harmful.
7. **A window built in code does not advertise full-screen support.** Without
   `collectionBehavior.insert(.fullScreenPrimary)` the green button only zooms and
   Enter Full Screen stays disabled.
8. **Zoom needs `windowWillUseStandardFrame(_:defaultFrame:)`.** AppKit derives its
   default standard frame from the content view's preferred size, and a text view
   has no intrinsic size -- so zoom (the green button, and double-clicking the
   title bar) appeared to do nothing. Returning `window.screen?.visibleFrame`
   makes it fill the display.

## Notes and limitations

- **Tabs always.** `tabbingMode = .preferred` deliberately overrides System
  Settings, including an explicit "Prefer tabs: Never".
- **Saving replaces symlinks.** `NSDocument`'s safe-save writes a temp file and
  swaps it in, so editing a symlinked dotfile (say `~/.zshrc` pointing into a
  dotfiles repo) replaces the symlink with a regular file.
- **Encoding detection is a guess** when a file is not UTF-8, and there is no
  encoding menu. Line endings (LF/CRLF/CR) and a UTF-8 BOM are detected on open and
  restored on save.
- **Untitled tabs do not come back.** Reopening on relaunch tracks file URLs, so
  unsaved new tabs have nothing to restore from.
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
