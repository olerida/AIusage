#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/AIusage.app"

: "${APPLE_SIGNING_IDENTITY:?Set APPLE_SIGNING_IDENTITY}"
: "${APPLE_NOTARY_PROFILE:?Set APPLE_NOTARY_PROFILE for xcrun notarytool}"

codesign --force --deep --options runtime --timestamp \
  --sign "$APPLE_SIGNING_IDENTITY" "$APP_PATH"
xcrun notarytool submit "$ROOT_DIR/dist/AIusage-macos-universal.zip" \
  --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" \
  "$ROOT_DIR/dist/AIusage-macos-universal-signed.zip"
