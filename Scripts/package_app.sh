#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="AIusage"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/AI Usage MB.app"
ARM_BUILD_DIR="$ROOT_DIR/.build/package-arm64"
X86_BUILD_DIR="$ROOT_DIR/.build/package-x86_64"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

swift build --package-path "$ROOT_DIR" --scratch-path "$ARM_BUILD_DIR" -c release --arch arm64
ARM_BIN_DIR="$(swift build --package-path "$ROOT_DIR" --scratch-path "$ARM_BUILD_DIR" --show-bin-path -c release --arch arm64)"
ARM_BIN="$ARM_BIN_DIR/$PRODUCT_NAME"
RESOURCE_BUNDLE="$ARM_BIN_DIR/AIusage_AIusage.bundle"

swift build --package-path "$ROOT_DIR" --scratch-path "$X86_BUILD_DIR" -c release --arch x86_64
X86_BIN="$(swift build --package-path "$ROOT_DIR" --scratch-path "$X86_BUILD_DIR" --show-bin-path -c release --arch x86_64)/$PRODUCT_NAME"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP_DIR/Contents/MacOS/$PRODUCT_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
chmod +x "$APP_DIR/Contents/MacOS/$PRODUCT_NAME"
if [[ ! -f "$APP_DIR/Contents/Resources/AIusage_AIusage.bundle/Info.plist" \
   && ! -f "$APP_DIR/Contents/Resources/AIusage_AIusage.bundle/Contents/Info.plist" ]]; then
  echo "Missing packaged SwiftPM resource bundle" >&2
  exit 1
fi

for language in es ca en; do
  if [[ -f "$RESOURCE_BUNDLE/$language.lproj/InfoPlist.strings" ]]; then
    mkdir -p "$APP_DIR/Contents/Resources/$language.lproj"
    cp "$RESOURCE_BUNDLE/$language.lproj/InfoPlist.strings" "$APP_DIR/Contents/Resources/$language.lproj/InfoPlist.strings"
  fi
done

if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --deep --options runtime --timestamp \
    --sign "$APPLE_SIGNING_IDENTITY" "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/AIusage-macos-universal.zip"
echo "Created $DIST_DIR/AIusage-macos-universal.zip"
