#!/usr/bin/env bash
set -euo pipefail

APP='build/macos/Build/Products/Release/TNote.app'
OUTPUT_DIR='artifacts/macos'
OUTPUT_NAME="${OUTPUT_NAME:-TNote-macOS.zip}"
mkdir -p "$OUTPUT_DIR"

if [[ -n "${MACOS_SIGNING_IDENTITY:-}" ]]; then
  while IFS= read -r binary; do
    codesign --force --options runtime --timestamp --sign "$MACOS_SIGNING_IDENTITY" "$binary"
  done < <(find "$APP/Contents/Frameworks" -type f \( -name '*.dylib' -o -perm -111 \) -print)
  while IFS= read -r framework; do
    codesign --force --options runtime --timestamp --sign "$MACOS_SIGNING_IDENTITY" "$framework"
  done < <(find "$APP/Contents/Frameworks" -depth -type d -name '*.framework' -print)
  codesign --force --options runtime --timestamp --sign "$MACOS_SIGNING_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/$OUTPUT_NAME"

if [[ -n "${MACOS_SIGNING_IDENTITY:-}" && -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  xcrun notarytool submit "$OUTPUT_DIR/$OUTPUT_NAME" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
  xcrun stapler staple "$APP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/$OUTPUT_NAME"
fi
