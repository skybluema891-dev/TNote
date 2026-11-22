#!/usr/bin/env bash
set -euo pipefail

version="${1:?version required}"
build="${2:?build required}"
repository="${GITHUB_REPOSITORY:?repository required}"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required for publishing}"
assets=artifacts/macos
dmg_name="TNote-$version.dmg"
test -s "$assets/$dmg_name"
temp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tnote-sparkle.XXXXXX")"
trap 'rm -rf "$temp"' EXIT
archive="$temp/Sparkle-2.10.1.tar.xz"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz \
  --output "$archive"
printf '%s  %s\n' 1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27 "$archive" | shasum -a 256 -c -
tar -xJf "$archive" -C "$temp"
base="https://github.com/$repository/releases/download/v$version/"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$temp/bin/generate_appcast" \
  --ed-key-file - --maximum-deltas 0 --download-url-prefix "$base" "$assets"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$temp/bin/sign_update" \
  --ed-key-file - --verify "$assets/appcast.xml"
python3 - "$assets" "$dmg_name" "$base" "$version" "$build" <<'PY'
from pathlib import Path
import base64, sys
import xml.etree.ElementTree as ET

directory, name, base, version, build = sys.argv[1:]
assets = Path(directory)
items = ET.parse(assets / 'appcast.xml').findall('./channel/item')
assert len(items) == 1, 'Expected one stable item'
item = items[0]
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
assert item.findtext(ns + 'version') == build
assert item.findtext(ns + 'shortVersionString') == version
enclosure = item.find('enclosure')
assert enclosure is not None and enclosure.get('url') == base + name
assert int(enclosure.attrib['length']) == (assets / name).stat().st_size
assert len(base64.b64decode(enclosure.attrib[ns + 'edSignature'], validate=True)) == 64
PY
