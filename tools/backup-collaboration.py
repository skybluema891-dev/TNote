"""Create a private pre-migration backup. No note bodies are written to logs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
from contextlib import closing

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def backup_note(source, destination):
    with closing(sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True)) as src:
        with closing(sqlite3.connect(destination)) as dst:
            src.backup(dst)
            if dst.execute("PRAGMA integrity_check").fetchone() != ("ok",):
                raise ValueError("SQLite backup integrity check failed")
    with tempfile.TemporaryDirectory(dir=destination.parent) as directory:
        restored = Path(directory) / "restored.sqlite"
        shutil.copy2(destination, restored)
        with closing(sqlite3.connect(restored.as_uri() + "?mode=ro", uri=True)) as check:
            if check.execute("PRAGMA integrity_check").fetchone() != ("ok",):
                raise ValueError("restore verification failed")
            if check.execute("PRAGMA application_id").fetchone() != (0x544e4f54,):
                raise ValueError("unrecognized TNote document")
            check.execute("SELECT id, content FROM tabs").fetchall()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("notes", type=Path, nargs="*")
    args = parser.parse_args()
    profile = args.profile.resolve(strict=True)
    root = args.destination.resolve()
    if root == profile or root.is_relative_to(profile):
        raise ValueError("choose a separate backup directory")
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    records, notes, missing = [], set(args.notes), []
    def add(source, target):
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.suffix.lower() == ".tnote":
            backup_note(source, target)
        else:
            data = source.read_bytes()
            target.write_bytes(data)
            if source.read_bytes() != data or target.read_bytes() != data:
                raise OSError("file changed during backup")
        records.append({"original": str(source), "backup": str(target.relative_to(root)), "sha256": digest(target)})
    prefs = profile / "shared_preferences.json"
    if prefs.exists():
        add(prefs, root / "profile" / prefs.name)
        settings = json.loads((root / "profile" / prefs.name).read_bytes())
        for entry in json.loads(settings.get("recentFilesV1", "[]")):
            file = Path(entry["path"])
            if file.suffix.lower() == ".tnote":
                notes.add(file)
    for folder in ("backups","recovery","updates"):
        base = profile / folder
        if base.is_dir():
            for file in base.rglob("*"):
                if file.is_file() and not file.is_symlink() and file.suffix.lower() in (".tnote",".json"):
                    add(file, root / "profile" / file.relative_to(profile))
    for index, note in enumerate(sorted(notes)):
        if note.is_file():
            add(note, root / "documents" / str(index) / note.name)
        else:
            missing.append(str(note))
    (root / "manifest.json").write_text(json.dumps({"files":records,"unavailable":missing}, ensure_ascii=False,indent=2),encoding="utf-8")
    print("verified files:",len(records), "unavailable recent documents:",len(missing))

if __name__ == "__main__":
    main()