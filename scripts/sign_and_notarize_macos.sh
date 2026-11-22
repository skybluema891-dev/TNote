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

# Re-sign Sparkle's helper bundles before the framework, retaining the
# downloader's own sandbox entitlements.
frameworks="$APP/Contents/Frameworks"
sparkle="$frameworks/Sparkle.framework"
sparkle_version="$sparkle/Versions/Current"
for item in XPCServices/Installer.xpc Autoupdate Updater.app; do
  codesign "${codesign_args[@]}" --options runtime "$sparkle_version/$item"
done
codesign "${codesign_args[@]}" --options runtime --preserve-metadata=entitlements \
  "$sparkle_version/XPCServices/Downloader.xpc"
codesign "${codesign_args[@]}" --options runtime "$sparkle"

while IFS= read -r binary; do
  codesign "${codesign_args[@]}" "$binary"
done < <(find "$frameworks" -path "$sparkle" -prune -o -type f \( -name '*.dylib' -o -perm -111 \) -print)
while IFS= read -r framework; do
  codesign "${codesign_args[@]}" "$framework"
done < <(find "$frameworks" -depth -type d -name '*.framework' ! -path "$sparkle*" -print)

# Xcode has expanded the identifier in the sandbox entitlements. Use its
# concrete values when sealing the final application for distribution.
entitlements="$(mktemp "${TMPDIR:-/tmp}/tnote-release-entitlements.XXXXXX")"
trap 'rm -f "$entitlements"' EXIT
codesign --display --entitlements - --xml "$APP" > "$entitlements"
python3 - "$APP/Contents/Info.plist" "$entitlements" <<'PY'
import base64, plistlib, sys
from pathlib import Path
info, entitlements = (plistlib.loads(Path(path).read_bytes()) for path in sys.argv[1:])
identifier = info["CFBundleIdentifier"]
assert len(base64.b64decode(info["SUPublicEDKey"], validate=True)) == 32, "Missing update public key"
assert not entitlements.get("com.apple.security.get-task-allow", False)
assert entitlements["com.apple.security.app-sandbox"] is True
assert entitlements["com.apple.security.network.client"] is True
assert entitlements["com.apple.security.files.user-selected.read-write"] is True
assert sorted(entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"]) == [
    identifier + "-spki", identifier + "-spks",
]
PY
codesign "${codesign_args[@]}" --entitlements "$entitlements" "$APP"
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
