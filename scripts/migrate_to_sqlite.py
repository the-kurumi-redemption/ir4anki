#!/usr/bin/env python3
"""Stage 2 CLI Migration Tool: Import `~/anki-notes` + `reading.db` into Joplin-mode SQLite `StorageEngine`.

Usage:
  backend/.venv/bin/python scripts/migrate_to_sqlite.py \\
    --notes-dir ~/anki-notes \\
    --reading-db ~/.local/state/ir4anki/reading.db \\
    --target-dir ~/.local/share/ir4anki/storage-v1
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

from storage import LegacyMigrator, open_storage_engine  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--notes-dir",
        default=str(Path.home() / "anki-notes"),
        help="Path to legacy physical Markdown corpus directory",
    )
    parser.add_argument(
        "--reading-db",
        default=str(Path.home() / ".local" / "state" / "ir4anki" / "reading.db"),
        help="Path to legacy reading.db SQLite state file",
    )
    parser.add_argument(
        "--target-dir",
        required=True,
        help="Target directory where data.db and media/ sandbox will be created",
    )
    parser.add_argument(
        "--import-unreferenced-assets",
        action="store_true",
        help="Also import unreferenced image files found in corpus",
    )
    args = parser.parse_args()

    notes_dir = Path(args.notes_dir).expanduser().resolve()
    reading_db = Path(args.reading_db).expanduser().resolve() if args.reading_db else None
    target_dir = Path(args.target_dir).expanduser().resolve()

    if not notes_dir.is_dir():
        print(f"ERROR: notes directory does not exist: {notes_dir}", file=sys.stderr)
        return 1

    engine = open_storage_engine(target_dir)
    try:
        migrator = LegacyMigrator(engine, notes_dir, reading_db)
        report = migrator.run(
            import_unreferenced_assets=args.import_unreferenced_assets
        )
    finally:
        engine.close()

    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
