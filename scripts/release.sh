#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo '使い方: ./scripts/release.sh 1.3.1' >&2
  exit 1
fi
cd "$(dirname "$0")/.."
[[ -d .git ]] || { echo '先にGitリポジトリを初期化してください。' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo '未コミットの変更があります。' >&2; exit 1; }
grep -q "^## $VERSION" CHANGELOG.md || { echo "CHANGELOG.mdに ## $VERSION を追加してください。" >&2; exit 1; }

python3 - "$VERSION" <<'PY'
import re
import sys
from pathlib import Path

version = sys.argv[1]
pubspec = Path('pubspec.yaml')
text = pubspec.read_text(encoding='utf-8')
match = re.search(r'^version:\s*([0-9.]+)\+([0-9]+)\s*$', text, re.M)
if not match:
    raise SystemExit('pubspec.yamlのバージョンを読み取れません。')
build = int(match.group(2)) + 1
pubspec.write_text(re.sub(r'^version:\s*[0-9.]+\+[0-9]+\s*$', f'version: {version}+{build}', text, flags=re.M), encoding='utf-8')
for name, pattern, replacement in [
    ('installer/TNote.iss', r'#define MyAppVersion "[0-9.]+"', f'#define MyAppVersion "{version}"'),
    ('windows/runner/Runner.rc', r'#define VERSION_AS_STRING "[0-9.]+"', f'#define VERSION_AS_STRING "{version}"'),
]:
    path = Path(name)
    path.write_text(re.sub(pattern, replacement, path.read_text(encoding='utf-8')), encoding='utf-8')
PY

flutter pub get
flutter analyze
flutter test
git add pubspec.yaml pubspec.lock installer/TNote.iss windows/runner/Runner.rc CHANGELOG.md
git commit -m "TNote $VERSION"
git tag "v$VERSION"
read -r -p "mainとタグ v$VERSION をGitHubへpushしますか？（はい/いいえ） " answer
if [[ "$answer" == 'はい' ]]; then
  git push origin main
  git push origin "v$VERSION"
  echo 'GitHub ActionsのWindows・macOS自動リリースが開始されました。'
else
  echo "pushは行いませんでした。後で git push origin main と git push origin v$VERSION を実行できます。"
fi
