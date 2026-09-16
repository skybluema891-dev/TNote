import argparse
import hashlib
import json
from pathlib import Path


def changelog_notes(version: str) -> list[str]:
    lines = Path('CHANGELOG.md').read_text(encoding='utf-8').splitlines()
    notes: list[str] = []
    inside = False
    for line in lines:
        if line.startswith('## '):
            if inside:
                break
            inside = version in line
            continue
        if inside and line.startswith('- '):
            notes.append(line[2:].strip())
    return notes


parser = argparse.ArgumentParser()
parser.add_argument('--version', required=True)
parser.add_argument('--build', required=True, type=int)
parser.add_argument('--repository', required=True)
parser.add_argument('--assets', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--notes-output', required=True, type=Path)
args = parser.parse_args()

tag = f'v{args.version}'
base = f'https://github.com/{args.repository}/releases/download/{tag}'
windows_name = f'TNote-Setup-{args.version}.exe'
macos_name = f'TNote-{args.version}.dmg'
windows_file = args.assets / windows_name
windows_hash = hashlib.sha256(windows_file.read_bytes()).hexdigest()
notes = changelog_notes(args.version)
payload = {
    'version': args.version,
    'build': args.build,
    'windows_url': f'{base}/{windows_name}',
    'macos_url': f'{base}/{macos_name}',
    'release_url': f'https://github.com/{args.repository}/releases/tag/{tag}',
    'release_notes': notes,
    'minimum_schema_version': 2,
    'windows_sha256': windows_hash,
}
args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
args.notes_output.write_text(
    f'# TNote {args.version}\n\n' + '\n'.join(f'- {note}' for note in notes) + '\n',
    encoding='utf-8',
)
