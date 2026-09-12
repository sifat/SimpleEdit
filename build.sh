#!/bin/sh
# Builds SimpleEdit.app. This script is the entire substitute for an xcodeproj:
# SwiftPM has no first-party app-bundle support, so we assemble Contents/ by hand.
#
#   ./build.sh              arm64 only, for working on this machine
#   ./build.sh --universal  arm64 + x86_64, so it runs on Intel Macs too
#   ./build.sh --zip        also produce build/SimpleEdit.zip for sharing
set -eu

APP_NAME="SimpleEdit"
BUNDLE_ID="com.sifat.simpleedit"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/$APP_NAME.app"
PLIST="$ROOT/Resources/Info.plist"

# The deployment target is stated once, in Info.plist, and read from there. It
# used to be written here as well, and Package.swift states it a third time; a
# mismatch between this script and the plist gave a binary whose
# LC_BUILD_VERSION disagreed with LSMinimumSystemVersion, with no error.
# Package.swift cannot read a plist, so it is checked against it instead.
DEPLOY_TARGET="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
grep -q "\.macOS(\.v${DEPLOY_TARGET%%.*})" "$ROOT/Package.swift" || {
    echo "Package.swift's platform does not match Info.plist's LSMinimumSystemVersion ($DEPLOY_TARGET)" >&2
    exit 1
}

UNIVERSAL=0
MAKE_ZIP=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --zip) MAKE_ZIP=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# A zip is a release artefact, and a release is a tag: refuse to package a
# commit whose version does not match a tag on it. This is the check that
# would have caught three languages shipping on a build number that had
# already gone out as v1.3. Checked before the slow part, and before the
# release flow in the README is trusted from memory. ALLOW_UNTAGGED_ZIP=1 is
# for sharing a build that is not a release.
if [ "$MAKE_ZIP" -eq 1 ] && [ "${ALLOW_UNTAGGED_ZIP:-0}" != "1" ]; then
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
    tag="$(git -C "$ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
    if [ "$tag" != "v$version" ]; then
        echo "refusing --zip: Info.plist says $version but HEAD is tagged '${tag:-nothing}'" >&2
        echo "tag the release commit v$version first, or set ALLOW_UNTAGGED_ZIP=1 for a non-release build" >&2
        exit 1
    fi
fi

cd "$ROOT"
STAGE="$ROOT/.build/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"

build_arch() {
    arch="$1"
    triple="${arch}-apple-macosx${DEPLOY_TARGET}"
    echo "==> Swift ($arch)"
    swift build -c release --triple "$triple" --product "$APP_NAME"
    cp "$(swift build -c release --triple "$triple" --show-bin-path)/$APP_NAME" "$STAGE/$APP_NAME.$arch"

    echo "==> Go helper ($arch)"
    case "$arch" in
        arm64) goarch=arm64 ;;
        x86_64) goarch=amd64 ;;
    esac
    # jsonfmt uses only the standard library, so it cross-compiles without cgo.
    CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" \
        go build -ldflags="-s -w" -o "$STAGE/jsonfmt.$arch" ./tools/jsonfmt
}

build_arch arm64
[ "$UNIVERSAL" -eq 1 ] && build_arch x86_64

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PLIST" "$APP/Contents/Info.plist"
# Regenerate with: xcrun swift tools/appicon/make-icon.swift
# Unconditional. The icon is tracked, and the `[ -f ] && cp` this used to be
# was exempt from set -e, so a missing icon shipped an app with the generic
# document icon and a dangling CFBundleIconFile -- no error, no warning.
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Syntax-highlighting queries. Vendored under Resources/Queries rather than read
# from the grammar's own SwiftPM resource bundle -- see
# Resources/Queries/html/SOURCE.md. Copying the whole tree means adding a
# language needs no change here. This must land BEFORE codesign, which seals
# Contents/Resources into _CodeSignature/CodeResources.
cp -R "$ROOT/Resources/Queries" "$APP/Contents/Resources/"
# set -eu already fails on a missing source directory; this catches the subtler
# case where the copy "succeeds" but a file we actually load is not there.
# Without it the failure surfaces only at runtime, as a document that silently
# refuses to highlight -- and for the injections files not even that: the
# parser is fail-soft about them, so a lost injections.scm means every <script>
# body quietly goes plain. So the whole tree is compared, file for file, not
# just highlights.scm: the injections queries, and the LICENSE files that ship
# for compliance. Finder droppings are removed rather than compared, since a
# .DS_Store must not end up inside the signed bundle either.
find "$APP/Contents/Resources/Queries" -name .DS_Store -delete
(cd "$ROOT/Resources/Queries" && find . -type f -not -name .DS_Store | sort) > "$STAGE/queries.expected"
(cd "$APP/Contents/Resources/Queries" && find . -type f | sort) > "$STAGE/queries.bundled"
cmp -s "$STAGE/queries.expected" "$STAGE/queries.bundled" || {
    echo "queries in the bundle differ from Resources/Queries:" >&2
    diff "$STAGE/queries.expected" "$STAGE/queries.bundled" >&2 || true
    exit 1
}

if [ "$UNIVERSAL" -eq 1 ]; then
    lipo -create "$STAGE/$APP_NAME.arm64" "$STAGE/$APP_NAME.x86_64" -output "$APP/Contents/MacOS/$APP_NAME"
    lipo -create "$STAGE/jsonfmt.arm64"   "$STAGE/jsonfmt.x86_64"   -output "$APP/Contents/MacOS/jsonfmt"
else
    cp "$STAGE/$APP_NAME.arm64" "$APP/Contents/MacOS/$APP_NAME"
    cp "$STAGE/jsonfmt.arm64"   "$APP/Contents/MacOS/jsonfmt"
fi

# Signing is mandatory, not cosmetic: arm64 macOS refuses to execute an unsigned
# Mach-O, and lipo invalidates whatever signature the linker applied. Sign the
# nested helper first, then the bundle. Do NOT use --deep -- `man codesign`:
# "DEPRECATED for signing as of macOS 13.0".
echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP/Contents/MacOS/jsonfmt"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
# Cheap insurance against a future step landing after the signature: nothing
# below may touch the bundle, and this is what says so.
codesign --verify --strict "$APP"

if [ "$MAKE_ZIP" -eq 1 ]; then
    ZIP="$ROOT/build/$APP_NAME.zip"
    rm -f "$ZIP"
    # ditto, not zip: it preserves the bundle structure and the signature.
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> Packaged $ZIP"
fi

echo "==> Built $APP  ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
