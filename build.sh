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
DEPLOY_TARGET="14.0"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/$APP_NAME.app"

UNIVERSAL=0
MAKE_ZIP=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --zip) MAKE_ZIP=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

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
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Regenerate with: xcrun swift tools/appicon/make-icon.swift
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Syntax-highlighting queries. Vendored under Resources/Queries rather than read
# from the grammar's own SwiftPM resource bundle -- see
# Resources/Queries/html/SOURCE.md. Copying the whole tree means adding a
# language needs no change here. This must land BEFORE codesign, which seals
# Contents/Resources into _CodeSignature/CodeResources.
cp -R "$ROOT/Resources/Queries" "$APP/Contents/Resources/"
# set -eu already fails on a missing source directory; this catches the subtler
# case where the copy "succeeds" but the file we actually load is not there.
# Without it the failure surfaces only at runtime, as a document that silently
# refuses to highlight.
[ -f "$APP/Contents/Resources/Queries/html/highlights.scm" ] || {
    echo "queries missing from bundle" >&2
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

if [ "$MAKE_ZIP" -eq 1 ]; then
    ZIP="$ROOT/build/$APP_NAME.zip"
    rm -f "$ZIP"
    # ditto, not zip: it preserves the bundle structure and the signature.
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> Packaged $ZIP"
fi

echo "==> Built $APP  ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
