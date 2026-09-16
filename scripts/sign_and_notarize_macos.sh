#!/usr/bin/env bash
set -euo pipefail

APP='build/macos/Build/Products/Release/TNote.app'
OUTPUT_DIR='artifacts/macos'
DMG_NAME="${DMG_NAME:-TNote.dmg}"
DMG="$OUTPUT_DIR/$DMG_NAME"
signing_identity="${MACOS_SIGNING_IDENTITY:--}"
codesign_args=(--force --sign "$signing_identity")
if [[ "$signing_identity" != '-' ]]; then
  codesign_args+=(--options runtime --timestamp)
fi

# Flutter/Xcode can update App.framework after its build-time signature. Sign
# every nested binary and framework from the inside out before sealing the app.
while IFS= read -r binary; do
  codesign "${codesign_args[@]}" "$binary"
done < <(find "$APP/Contents/Frameworks" -type f \( -name '*.dylib' -o -perm -111 \) -print)
while IFS= read -r framework; do
  codesign "${codesign_args[@]}" "$framework"
done < <(find "$APP/Contents/Frameworks" -depth -type d -name '*.framework' -print)
codesign "${codesign_args[@]}" \
  --entitlements macos/Runner/Release.entitlements \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

OUTPUT_DIR="$OUTPUT_DIR" DMG_NAME="$DMG_NAME" \
  bash scripts/create_macos_dmg.sh

notary_values=(
  "${APPLE_ID:-}"
  "${APPLE_APP_PASSWORD:-}"
  "${APPLE_TEAM_ID:-}"
)
configured=0
for value in "${notary_values[@]}"; do
  [[ -n "$value" ]] && configured=$((configured + 1))
done

if (( configured > 0 && configured < 3 )); then
  echo '公証用のAPPLE_ID、APPLE_APP_PASSWORD、APPLE_TEAM_IDは3つすべて設定してください。' >&2
  exit 1
fi
if [[ $configured -eq 3 && "$signing_identity" == '-' ]]; then
  echo '公証にはMACOS_SIGNING_IDENTITYとDeveloper ID証明書が必要です。' >&2
  exit 1
fi

if [[ $configured -eq 3 ]]; then
  xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
