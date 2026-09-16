#!/usr/bin/env bash
set -euo pipefail

APP="${APP_PATH:-build/macos/Build/Products/Release/TNote.app}"
OUTPUT_DIR="${OUTPUT_DIR:-artifacts/macos}"
DMG_NAME="${DMG_NAME:-TNote.dmg}"
VOLUME_NAME="${VOLUME_NAME:-TNote}"

if [[ ! -d "$APP" ]]; then
  echo "TNote.appが見つかりません。先にflutter build macos --releaseを実行してください。" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
staging="$(mktemp -d "${TMPDIR:-/tmp}/tnote-dmg.XXXXXX")"
cleanup() {
  rm -rf "$staging"
}
trap cleanup EXIT

ditto "$APP" "$staging/TNote.app"
ln -s /Applications "$staging/Applications"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$staging" \
  -format UDZO \
  -ov \
  "$OUTPUT_DIR/$DMG_NAME"
hdiutil verify "$OUTPUT_DIR/$DMG_NAME"
echo "$OUTPUT_DIR/$DMG_NAME"
