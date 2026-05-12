#!/bin/bash
# Wrap the SPM-built roon-key binary into a proper macOS .app bundle.
#
# SPM produces only a bare executable, which cannot be granted Accessibility
# permission (no stable bundle identifier) and does not behave as a menubar
# app under LSUIElement. This script assembles the conventional .app layout
# around the binary and the Info.plist that ships in Sources/.
#
# Usage:
#   scripts/make-app.sh                  # release build, output to build/
#   scripts/make-app.sh --debug          # debug build
#   scripts/make-app.sh --output ~/Apps  # custom output dir
#   scripts/make-app.sh --install        # also copy to /Applications
#   scripts/make-app.sh --run            # also launch after build

set -euo pipefail

CONFIG="release"
OUTPUT_DIR=""
INSTALL=0
RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) CONFIG="debug"; shift ;;
        --release) CONFIG="release"; shift ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --install) INSTALL=1; shift ;;
        --run) RUN=1; shift ;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$REPO_ROOT/build"
fi
mkdir -p "$OUTPUT_DIR"

APP_NAME="roon-key"
APP_BUNDLE="$OUTPUT_DIR/${APP_NAME}.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$REPO_ROOT/.build/$CONFIG/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Build did not produce $BIN_PATH" >&2
    exit 1
fi

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$REPO_ROOT/Sources/roon-key/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# CFBundleExecutable must match the binary name in MacOS/. The shipped
# Info.plist omits it, so inject it here using PlistBuddy.
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" \
    "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" \
        "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" \
    "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" \
    "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

# Sign the bundle. Prefer a stable self-signed identity (set
# ROON_KEY_SIGN_IDENTITY in your shell rc to the name of a code-signing
# cert in your login keychain). Ad-hoc is a fallback but will re-trigger
# the TCC/Accessibility prompt on every rebuild because the cdhash
# changes. With a named identity, TCC keys on the cert's designated
# requirement and the grant persists across rebuilds.
SIGN_IDENTITY="${ROON_KEY_SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> codesign --sign - (ad-hoc; TCC will re-prompt on every rebuild)"
    echo "    To make Accessibility grants stick, see scripts/README-signing.md"
else
    echo "==> codesign --sign \"$SIGN_IDENTITY\""
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

echo "==> built $APP_BUNDLE"

if [[ $INSTALL -eq 1 ]]; then
    DEST="/Applications/${APP_NAME}.app"
    echo "==> installing to $DEST"
    rm -rf "$DEST"
    cp -R "$APP_BUNDLE" "$DEST"
    APP_BUNDLE="$DEST"
fi

if [[ $RUN -eq 1 ]]; then
    echo "==> open $APP_BUNDLE"
    open "$APP_BUNDLE"
fi
