#!/usr/bin/env python3
"""Stage 2 Migration Test Suite (`scripts/storage_migration_test.py`).

Tests:
1. Synthetic legacy corpus + `reading.db` migration:
   - Nested folders -> `notebooks` hierarchy
   - Relative `_assets/` and root `_assets/` images -> `resources` sandbox + `(:/<id>)` rewrite
   - External `https://` links untouched
   - Listed & archived `rfiles` -> `notes` with exact `in_list`, `list_pos`, `added_at`
   - Split segments + `rcards` -> `segments` + `segment_cards` with recomputed fingerprints
     matching rewritten `(:/<id>)` lines (zero false drift!)
   - Deleted/missing archived `rfiles` with cards -> soft-deleted `notes` preserving card provenance
   - Idempotent re-run produces zero duplicate notes/segments/cards
2. Real backup snapshot dry-run verification (when backup snapshot is present on disk):
   - Runs `LegacyMigrator` against the read-only backup snapshot
     `~/.local/share/ir4anki/ops-backups/pre-storage-phase1-20261114/20261114T062600.069653Z`
     into an isolated temporary target directory and verifies 100% card provenance (1,009 cards)
     and 0 unresolved image links across all 2,484 local image references.
"""
from __future__ import annotations

import sqlite3
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

from storage import (  # noqa: E402
    LegacyMigrator,
    open_storage_engine,
    reanchor_segments,
    seg_fingerprint,
)

passed = 0
failed = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name} {f'({detail})' if detail else ''}")


def test_synthetic_corpus_and_reading_db_migration() -> None:
    print("\n=== 1. Synthetic Legacy Corpus + reading.db Migration ===")
    with tempfile.TemporaryDirectory(prefix="ir4anki-mig-test-") as tmp:
        tmp_path = Path(tmp)
        notes_dir = tmp_path / "anki-notes"
        reading_db = tmp_path / "reading.db"
        target_dir = tmp_path / "storage-out"

        # Build legacy directory structure
        (notes_dir / "_assets").mkdir(parents=True)
        (notes_dir / "2026" / "医学免疫学" / "_assets").mkdir(parents=True)

        img_root_bytes = b"\x89PNG\r\n\x1a\nroot_asset_png_bytes"
        img_book_bytes = b"\x89PNG\r\n\x1a\nbook_asset_png_bytes"
        (notes_dir / "_assets" / "paste-root.png").write_bytes(img_root_bytes)
        (notes_dir / "2026" / "医学免疫学" / "_assets" / "fig1.png").write_bytes(img_book_bytes)

        md1_path = "2026/医学免疫学/第一章-免疫学概论.md"
        md1_text = "\n".join(
            [
                "# 第一章 免疫学概论",
                "第一段：免疫系统的基本功能包括免疫防御、免疫自稳和免疫监视。",
                "第二段：请参考配图 ![图1](_assets/fig1.png) 以及全局贴图 ![](paste-root.png)。",
                "第三段：外链图片保持不变 ![ext](https://example.com/chart.png) 继续阅读尾部。",
            ]
        )
        (notes_dir / md1_path).write_text(md1_text, encoding="utf-8")

        md2_path = "2026/随笔.md"
        md2_text = "# 随笔\n\n这是一篇尚未加入阅读清单的普通笔记，应当自动整篇播种。"
        (notes_dir / md2_path).parent.mkdir(parents=True, exist_ok=True)
        (notes_dir / md2_path).write_text(md2_text, encoding="utf-8")

        # Create legacy reading.db with 1 listed file (md1) + 1 deleted archived file with a card
        conn = sqlite3.connect(reading_db)
        conn.executescript(
            """
            CREATE TABLE rfiles (
                path TEXT PRIMARY KEY,
                in_list INTEGER NOT NULL DEFAULT 1,
                pos INTEGER NOT NULL DEFAULT 0,
                added_at TEXT,
                file_sha TEXT,
                needs_resync INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE segments (
                path TEXT NOT NULL,
                seg_id INTEGER NOT NULL,
                start_line INTEGER NOT NULL,
                end_line INTEGER NOT NULL,
                fingerprint TEXT NOT NULL DEFAULT '',
                first_line TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '',
                heading_path TEXT NOT NULL DEFAULT '[]',
                status TEXT NOT NULL DEFAULT 'todo',
                parent_seg_id INTEGER,
                updated_at TEXT,
                PRIMARY KEY (path, seg_id)
            );
            CREATE TABLE rcards (
                path TEXT NOT NULL,
                seg_id INTEGER NOT NULL,
                note_id INTEGER NOT NULL
            );
            CREATE TABLE rorphans (
                path TEXT NOT NULL,
                chunk_key TEXT NOT NULL,
                data TEXT
            );
            CREATE TABLE rround (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                data TEXT
            );
            """
        )
        md1_lines = md1_text.split("\n")
        conn.execute(
            "INSERT INTO rfiles VALUES (?, 1, 0, '2026-11-01T10:00:00', 'oldsha', 0)",
            (md1_path,),
        )
        # Segment 1 (container 1..4), Segment 2 (done 1..2), Segment 3 (active 3..4 with image link!)
        conn.execute(
            "INSERT INTO segments VALUES (?, 1, 1, 4, ?, ?, '第一章 免疫学概论', '[]', 'container', NULL, '2026-11-01T10:05:00')",
            (md1_path, seg_fingerprint(md1_lines, 1, 4), md1_lines[0]),
        )
        conn.execute(
            "INSERT INTO segments VALUES (?, 2, 1, 2, ?, ?, '第一章 免疫学概论', '[]', 'done', 1, '2026-11-01T10:05:00')",
            (md1_path, seg_fingerprint(md1_lines, 1, 2), md1_lines[0]),
        )
        conn.execute(
            "INSERT INTO segments VALUES (?, 3, 3, 4, ?, ?, '第一章 免疫学概论', '[]', 'active', 1, '2026-11-01T10:05:00')",
            (md1_path, seg_fingerprint(md1_lines, 3, 4), md1_lines[2]),
        )
        conn.execute("INSERT INTO rcards VALUES (?, 1, 50001)", (md1_path,))
        conn.execute("INSERT INTO rcards VALUES (?, 3, 50002)", (md1_path,))

        # Deleted archived file that still holds Anki card 50003
        deleted_path = "2026/已删除旧书/第一章.md"
        conn.execute(
            "INSERT INTO rfiles VALUES (?, 0, 0, NULL, 'delsha', 0)",
            (deleted_path,),
        )
        conn.execute(
            "INSERT INTO segments VALUES (?, 1, 1, 5, 'delfp', '# 旧书第一章摘要', '第一章', '[]', 'done', NULL, '2026-10-01T00:00:00')",
            (deleted_path,),
        )
        conn.execute("INSERT INTO rcards VALUES (?, 1, 50003)", (deleted_path,))
        conn.commit()
        conn.close()

        eng = open_storage_engine(target_dir)
        migrator = LegacyMigrator(eng, notes_dir, reading_db)
        rep = migrator.run()

        check("migration report ok", rep["ok"] is True, str(rep))
        check("migrated 2 live notes + 1 archived missing note", rep["notes_migrated"] == 2 and rep["archived_missing_notes_migrated"] == 1)
        check("rewrote 2 local image links and left external https link untouched", rep["markdown_image_links_rewritten"] == 2 and len(rep["unresolved_image_links"]) == 0)
        check("imported 2 unique resources", rep["unique_resources_stored"] == 2)
        check("migrated all 3 Anki card links", rep["segment_cards_migrated"] == 3)

        # Verify rewritten note body & segment fingerprints match (no drift!)
        n1 = eng.get_note_by_legacy_path(md1_path, include_segments=True)
        check("n1 exists and is in reading list", n1 is not None and n1["in_list"] is True)
        check("n1 body contains :/resource_id links and preserves https:// link", "](:/" in n1["body"] and "https://example.com/chart.png" in n1["body"])

        # Re-anchor check against n1["body"] should report damaged=False
        _, _, damaged = reanchor_segments(n1["segments"], n1["orphans"], n1["body"].split("\n"))
        check("rewritten segment fingerprints match rewritten body lines (damaged=False)", not damaged)

        # Provenance lookup for card 50002 (on live note) and 50003 (on deleted archived note)
        src_live = eng.find_card_source(50002)
        check(
            "card 50002 resolves to live note seg 3 with ancestor container 1",
            src_live is not None
            and src_live["note_id"] == n1["id"]
            and not src_live["note_deleted"]
            and [b["seg_id"] for b in src_live["breadcrumb"]] == [1, 3],
        )
        src_del = eng.find_card_source(50003)
        check(
            "card 50003 on missing archived file still resolves provenance via soft-deleted note",
            src_del is not None
            and src_del["legacy_path"] == deleted_path
            and src_del["note_deleted"] is True,
        )

        # Idempotent second run
        rep2 = migrator.run()
        check(
            "idempotent second run keeps identical counts",
            rep2["ok"] is True
            and len(eng.list_notes(include_deleted=True)) == 3
            and rep2["segment_cards_migrated"] == 3,
        )
        eng.close()


def test_real_backup_snapshot_dry_run() -> None:
    print("\n=== 2. Dry-Run Migration on Real Backup Snapshot ===")
    snap = Path(
        "/home/shioriko/.local/share/ir4anki/ops-backups/pre-storage-phase1-20261114/20261114T062600.069653Z"
    )
    if not snap.is_dir():
        print("  SKIP  Backup snapshot not present")
        return

    with tempfile.TemporaryDirectory(prefix="ir4anki-real-mig-dryrun-") as tmp:
        eng = open_storage_engine(Path(tmp) / "storage-v1")
        migrator = LegacyMigrator(
            eng,
            snap / "corpus",
            snap / "state" / "reading.db",
        )
        rep = migrator.run()
        check("real corpus migration ok", rep["ok"] is True, str(rep.get("health")))
        check("all 206 markdown files migrated", rep["notes_migrated"] == 206, str(rep["notes_migrated"]))
        check("all 7 missing archived rfiles migrated as soft-deleted", rep["archived_missing_notes_migrated"] == 7, str(rep["archived_missing_notes_migrated"]))
        check("all 2,484 local image links rewritten with 0 unresolved", rep["markdown_image_links_rewritten"] == 2484 and len(rep["unresolved_image_links"]) == 0, str(rep["markdown_image_links_rewritten"]))
        check("all 1,356 reading.db segments + 168 newly seeded whole-note segments present", rep["segments_migrated"] == 1356 + (206 - 38), str(rep["segments_migrated"]))
        check("100% of 1,009 rcards Anki provenance links migrated", rep["segment_cards_migrated"] == 1009, str(rep["segment_cards_migrated"]))

        listed = eng.list_notes(in_list_only=True)
        check("20 active notes in reading list", len(listed) == 20, str(len(listed)))

        # Verify FTS5 search on real migrated medical notes
        hits = eng.search_notes("固有免疫")
        check("FTS5 search on migrated medical corpus returns hits", len(hits) > 0)
        eng.close()


def main() -> int:
    test_synthetic_corpus_and_reading_db_migration()
    test_real_backup_snapshot_dry_run()
    print(f"\nSummary: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
