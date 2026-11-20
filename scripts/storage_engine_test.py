#!/usr/bin/env python3
"""Comprehensive test suite for Stage 1: Joplin-mode Storage Engine & DAO.

Covers:
1. Driver & Shim abstractions (SQLiteDatabaseDriver nested savepoints/rollback, LocalFsDriver, MemoryFsDriver)
2. Schema initialization & health/integrity checks
3. Notebooks DAO (hierarchical creation, duplicate rejection, rename, move, cycle prevention, soft delete, subtree restore, purge)
4. Notes & Revisions DAO (CRUD, optimistic concurrency, automatic revisions, time-travel rollback, move note, trash & empty trash)
5. Full-Text Search (FTS5 trigram + short CJK/ASCII fallback, soft-deleted exclusion)
6. Resources & Media Sandbox (`(:/<id>)` link extraction, SHA-256 deduplication, unreferenced GC)
7. Progressive Reading Segments DAO (whole-note seeding, bookmark split, in-app segment edit with line shifts, full-note drift re-anchoring & reseed, Anki card provenance & breadcrumb lookup, reading list ordering & round persistence)
8. Hot backup (`VACUUM INTO` + media copy) and restoration verification
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

from storage import (  # noqa: E402
    LocalFsDriver,
    MemoryFsDriver,
    PlatformShim,
    SCHEMA_VERSION,
    SQLiteDatabaseDriver,
    StorageConflictError,
    StorageEngine,
    StorageNotFoundError,
    open_storage_engine,
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


def test_drivers_and_nested_transactions() -> None:
    print("\n=== 1. Drivers & Nested Transactions (Savepoints) ===")
    db = SQLiteDatabaseDriver(":memory:")
    db.executescript("CREATE TABLE items (id TEXT PRIMARY KEY, val INTEGER);")

    with db.transaction():
        db.execute("INSERT INTO items VALUES ('a', 1)")
        try:
            with db.transaction():
                db.execute("INSERT INTO items VALUES ('b', 2)")
                raise RuntimeError("inner abort")
        except RuntimeError:
            pass
        db.execute("INSERT INTO items VALUES ('c', 3)")

    rows = db.query_all("SELECT id, val FROM items ORDER BY id")
    check(
        "outer tx commits 'a' and 'c' while inner savepoint rolls back 'b'",
        rows == [{"id": "a", "val": 1}, {"id": "c", "val": 3}],
        str(rows),
    )

    try:
        with db.transaction():
            db.execute("INSERT INTO items VALUES ('d', 4)")
            raise RuntimeError("outer abort")
    except RuntimeError:
        pass
    rows_after = db.query_all("SELECT id FROM items ORDER BY id")
    check("outer rollback discards 'd'", [r["id"] for r in rows_after] == ["a", "c"])
    db.close()

    # FsDriver traversal protection
    mem_fs = MemoryFsDriver()
    mem_fs.write_bytes("abc.png", b"12345")
    check("MemoryFsDriver stores & reads bytes", mem_fs.read_bytes("abc.png") == b"12345")
    traversal_blocked = False
    try:
        mem_fs.write_bytes("../evil.png", b"bad")
    except ValueError:
        traversal_blocked = True
    check("MemoryFsDriver blocks path traversal", traversal_blocked)


def test_notebooks_hierarchy_and_trash() -> None:
    print("\n=== 2. Notebooks Hierarchy, Cycle Guard & Soft Delete ===")
    eng = open_storage_engine(in_memory=True)
    health = eng.check_health()
    check("initial health & schema_version", health["ok"] and health["schema_version"] == SCHEMA_VERSION)

    nb_root = eng.create_notebook("2026")
    nb_book = eng.create_notebook("金钱心理学", parent_id=nb_root["id"])
    nb_ch1 = eng.create_notebook("第一章", parent_id=nb_book["id"])

    # Duplicate sibling name check
    dup_blocked = False
    try:
        eng.create_notebook("金钱心理学", parent_id=nb_root["id"])
    except StorageConflictError:
        dup_blocked = True
    check("duplicate sibling notebook name rejected", dup_blocked)

    # Breadcrumb path
    trail = eng.get_notebook_path(nb_ch1["id"])
    check(
        "get_notebook_path returns root-to-leaf trail",
        [t["name"] for t in trail] == ["2026", "金钱心理学", "第一章"],
        str(trail),
    )

    # Cycle prevention: cannot move 2026 into 第一章
    cycle_blocked = False
    try:
        eng.move_notebook(nb_root["id"], nb_ch1["id"])
    except StorageConflictError:
        cycle_blocked = True
    check("move_notebook prevents moving ancestor into descendant", cycle_blocked)

    # Self-move prevention
    self_blocked = False
    try:
        eng.move_notebook(nb_root["id"], nb_root["id"])
    except StorageConflictError:
        self_blocked = True
    check("move_notebook prevents moving notebook into itself", self_blocked)

    # Resolve or create slash path
    leaf_id = eng.resolve_or_create_notebook_path("2026/金钱心理学/第二章")
    trail2 = eng.get_notebook_path(leaf_id)
    check(
        "resolve_or_create_notebook_path reuses existing and creates missing",
        [t["name"] for t in trail2] == ["2026", "金钱心理学", "第二章"],
    )

    # Create a note inside 第一章, then soft-delete nb_book
    note = eng.create_note(
        "靠运气与冒风险",
        "# 靠运气与冒风险\n\n运气和风险是现实中每一项结果都受作用力影响的兄弟。",
        notebook_id=nb_ch1["id"],
    )
    del_res = eng.soft_delete_notebook(nb_book["id"])
    check("soft_delete_notebook cascades to 3 notebooks and 1 note", del_res["notebooks_deleted"] == 3 and del_res["notes_deleted"] == 1)
    check("deleted note hidden from get_note", eng.get_note(note["id"]) is None)

    # Restore leaf note automatically restores ancestor notebook chain
    eng.restore_note(note["id"])
    check("restore_note brings note back", eng.get_note(note["id"]) is not None)
    check("restore_note restores parent notebook chain", eng.get_notebook(nb_book["id"]) is not None and eng.get_notebook(nb_ch1["id"]) is not None)
    eng.close()


def test_notes_revisions_and_fts() -> None:
    print("\n=== 3. Notes, Revisions Rollback & FTS5 Search ===")
    eng = open_storage_engine(in_memory=True)
    n1 = eng.create_note(
        "复利之谜",
        "# 复利之谜\n\n沃伦·巴菲特的净资产中有815亿美元是在他65岁生日之后积累的。",
        in_list=True,
    )
    revs_initial = eng.list_note_revisions(n1["id"])
    check("create_note records initial revision", len(revs_initial) == 1 and revs_initial[0]["reason"] == "create")

    # Optimistic concurrency guard
    conflict_caught = False
    try:
        eng.update_note(n1["id"], body="篡改内容", expected_body_sha="wrong_sha")
    except StorageConflictError:
        conflict_caught = True
    check("update_note rejects mismatched expected_body_sha", conflict_caught)

    # Valid update creates 2nd revision
    n1_v2 = eng.update_note(
        n1["id"],
        title="复利之谜（修订版）",
        body="# 复利之谜（修订版）\n\n优秀的投资并不必然意味着赚取最高的回报，而是长期坚持。",
        expected_body_sha=n1["body_sha"],
    )
    revs_v2 = eng.list_note_revisions(n1["id"])
    check("update_note records 2nd revision", len(revs_v2) == 2)

    # Full-Text Search (3+ chars via FTS5 trigram, 2 chars via fallback)
    hits_fts = eng.search_notes("长期坚持")
    check("search_notes finds Chinese phrase via FTS5 trigram", len(hits_fts) == 1 and hits_fts[0]["id"] == n1["id"])

    hits_short = eng.search_notes("复利")
    check("search_notes finds 2-char CJK query", len(hits_short) == 1 and hits_short[0]["id"] == n1["id"])

    # Time-travel rollback to initial revision
    initial_rev_id = revs_initial[0]["id"]
    n1_restored = eng.restore_note_revision(n1["id"], initial_rev_id)
    check(
        "restore_note_revision rolls back title and body",
        n1_restored["title"] == "复利之谜" and "815亿美元" in n1_restored["body"],
    )
    revs_v3 = eng.list_note_revisions(n1["id"])
    check("restore_note_revision appends restore revision", len(revs_v3) == 3 and revs_v3[0]["reason"].startswith("restore:"))

    # Soft delete hides from search
    eng.soft_delete_note(n1["id"])
    check("soft-deleted note excluded from search_notes", len(eng.search_notes("815亿美元")) == 0)
    trash = eng.list_trash()
    check("list_trash shows deleted note", len(trash["notes"]) == 1)
    purged = eng.empty_trash()
    check("empty_trash permanently removes note", purged["notes_purged"] == 1 and eng.get_note(n1["id"], include_deleted=True) is None)
    eng.close()


def test_resources_and_gc() -> None:
    print("\n=== 4. Resources Sandbox, Deduplication & Link GC ===")
    eng = open_storage_engine(in_memory=True)
    img_bytes = b"\x89PNG\r\n\x1a\nfake_png_payload_123456"
    r1 = eng.put_resource("diagram.png", img_bytes, legacy_name="diagram.png")
    r2 = eng.put_resource("duplicate_name.png", img_bytes)
    check("put_resource deduplicates identical SHA-256 + ext", r1["id"] == r2["id"])
    check("markdown_ref uses Joplin :/id syntax", r1["markdown_ref"] == f":/{r1['id']}")

    r_unused = eng.put_resource("orphan.jpg", b"jpeg_payload_unused")

    # Create note referencing r1
    md = f"# 图解笔记\n\n请看这张图：![架构图](:/{r1['id']})\n\n正文长度足够生成渐进阅读切片。"
    note = eng.create_note("图解笔记", md)

    unref = eng.find_unreferenced_resources()
    check(
        "find_unreferenced_resources identifies only unlinked resource",
        [u["id"] for u in unref] == [r_unused["id"]],
    )

    gc_count = eng.gc_unreferenced_resources()
    check("gc_unreferenced_resources deletes unlinked blob & row", gc_count == 1 and eng.get_resource(r_unused["id"]) is None)
    check("referenced resource survives GC", eng.get_resource(r1["id"]) is not None)

    # Removing link from note makes r1 eligible for GC
    eng.update_note(note["id"], body="# 图解笔记\n\n已移除图片引用，只保留纯文本内容。")
    check("after link removal in note, resource becomes unreferenced", len(eng.find_unreferenced_resources()) == 1)
    eng.close()


def test_segments_split_edit_reanchor_and_provenance() -> None:
    print("\n=== 5. Progressive Reading Segments: Split, Edit, Reanchor & Provenance ===")
    eng = open_storage_engine(in_memory=True)
    lines = [
        "# 渐进阅读测试章节",
        "第一段：背景介绍内容，这一段我们在切分时不选中，让它自动成为 background。",
        "第二段：核心知识点 A，这是我们需要重点制卡的第一处选区内容。",
        "第三段：过渡段内容，也不选中，自动成为中间的 background 段落。",
        "第四段：核心知识点 B，这是我们需要重点制卡的第二处选区内容。",
        "第五段：未读尾部内容，保留在最后，切分后应自动成为延后阅读的 tail todo。",
        "第六段：尾部补充说明，确保未读尾部拥有充足的有效字数。",
    ]
    note = eng.create_note("渐进阅读测试章节", "\n".join(lines), in_list=True)
    segs0 = note["segments"]
    check("whole-note seeded as 1 todo segment covering lines 1..7", len(segs0) == 1 and segs0[0]["start_line"] == 1 and segs0[0]["end_line"] == 7)

    # Attach an Anki card (10001) to root segment 1 BEFORE splitting (provenance preservation rule)
    eng.record_segment_card(note["id"], 1, 10001)
    segs_active = eng.get_note_segments(note["id"])
    check("record_segment_card marks todo segment active and records card", segs_active[0]["status"] == "active" and segs_active[0]["cards_created"] == [10001])

    # Bookmark split on segment 1: select line 3 and line 5
    split_res = eng.split_segment(
        note["id"],
        1,
        [{"start_line": 3, "end_line": 3}, {"start_line": 5, "end_line": 5}],
        expected_fingerprint=segs_active[0]["fingerprint"],
        expected_line_start=1,
    )
    children = split_res["children"]
    statuses = [(c["seg_id"], c["start_line"], c["end_line"], c["status"]) for c in children]
    expected_statuses = [
        (2, 1, 2, "background"),
        (3, 3, 3, "todo"),
        (4, 4, 4, "background"),
        (5, 5, 5, "todo"),
        (6, 6, 7, "todo"),  # tail
    ]
    check("split_segment produces 2k+1 children with background gaps and todo tail", statuses == expected_statuses, str(statuses))
    check("tail_seg_id is 6", split_res["tail_seg_id"] == 6)

    # Attach Anki card 10002 to child segment 3
    eng.record_segment_card(note["id"], 3, 10002)

    # In-app edit on segment 3: expand from 1 line to 3 lines (delta = +2)
    seg3_before = next(s for s in eng.get_note_segments(note["id"]) if s["seg_id"] == 3)
    edit_res = eng.edit_segment(
        note["id"],
        3,
        "第二段（扩写行1）：核心知识点 A 详细展开\n第二段（扩写行2）：补充公式推导\n第二段（扩写行3）：小结",
        expected_fingerprint=seg3_before["fingerprint"],
    )
    check("edit_segment delta is +2", edit_res["delta"] == 2)
    segs_after_edit = {s["seg_id"]: s for s in eng.get_note_segments(note["id"])}
    check("edited segment 3 now spans lines 3..5", (segs_after_edit[3]["start_line"], segs_after_edit[3]["end_line"]) == (3, 5))
    check("subsequent segment 5 shifted by +2 to lines 7..7", (segs_after_edit[5]["start_line"], segs_after_edit[5]["end_line"]) == (7, 7))
    check("tail segment 6 shifted by +2 to lines 8..9", (segs_after_edit[6]["start_line"], segs_after_edit[6]["end_line"]) == (8, 9))
    check("ancestor container 1 stretched to 1..9", (segs_after_edit[1]["start_line"], segs_after_edit[1]["end_line"]) == (1, 9))

    # Reverse provenance lookup for card 10002
    src = eng.find_card_source(10002)
    check(
        "find_card_source resolves note, segment 3, edited text, and 2-level breadcrumb",
        src is not None
        and src["note_id"] == note["id"]
        and src["seg_id"] == 3
        and "补充公式推导" in src["text"]
        and [b["seg_id"] for b in src["breadcrumb"]] == [1, 3]
        and src["breadcrumb"][0]["cards_created"] == [10001],
    )

    # Simulate external/full-note edit that modifies segment 5's text -> triggers needs_resync, then reseed
    note_curr = eng.get_note(note["id"])
    mutated_body = note_curr["body"].replace("第四段：核心知识点 B，这是我们需要重点制卡的第二处选区内容。", "第四段已被重写为全新内容：量子力学基本假设与波函数坍缩。")
    updated_note = eng.update_note(note["id"], body=mutated_body)
    check("full-note edit modifying a leaf segment sets needs_resync=True", updated_note["needs_resync"] is True)

    reseed_res = eng.reseed_note(note["id"])
    note_reseeded = eng.get_note(note["id"], include_segments=True)
    check("reseed_note clears needs_resync and seeds uncovered run", not note_reseeded["needs_resync"] and reseed_res["fresh"] == 1)
    eng.close()


def test_disk_persistence_and_hot_backup() -> None:
    print("\n=== 6. Disk Persistence, VACUUM INTO Hot Backup & Health Check ===")
    with tempfile.TemporaryDirectory(prefix="ir4anki-storage-test-") as tmp:
        data_dir = Path(tmp) / "live"
        backup_dir = Path(tmp) / "backup"

        eng = open_storage_engine(data_dir)
        nb = eng.create_notebook("医学笔记")
        res = eng.put_resource("anatomy.png", b"\x89PNG_anatomy_blob_data")
        note = eng.create_note(
            "局部解剖学总论",
            f"# 局部解剖学总论\n\n![解剖图](:/{res['id']})\n\n人体局部解剖学重点内容梳理。",
            notebook_id=nb["id"],
            in_list=True,
        )
        eng.set_reading_round({"status": "active", "pending": [{"note_id": note["id"], "chunk_key": "1"}]})

        binfo = eng.backup(backup_dir)
        check("hot backup wrote data.db and copied media file", Path(binfo["db_path"]).is_file() and binfo["media_files"] == 1)
        eng.close()

        # Open backup copy as an independent StorageEngine and verify state
        eng_bak = open_storage_engine(backup_dir)
        health = eng_bak.check_health()
        check("backup engine passes integrity & blob health check", health["ok"], str(health["issues"]))
        bak_note = eng_bak.get_note(note["id"], include_segments=True)
        check("backup engine preserves note, notebook path, and segments", bak_note is not None and bak_note["notebook_path"][0]["name"] == "医学笔记" and len(bak_note["segments"]) == 1)
        _, raw_blob = eng_bak.read_resource_bytes(res["id"])
        check("backup engine preserves sandbox resource bytes", raw_blob == b"\x89PNG_anatomy_blob_data")
        rd = eng_bak.get_reading_round()
        check("backup engine preserves reading_round state", rd is not None and rd["status"] == "active")
        eng_bak.close()


def main() -> int:
    test_drivers_and_nested_transactions()
    test_notebooks_hierarchy_and_trash()
    test_notes_revisions_and_fts()
    test_resources_and_gc()
    test_segments_split_edit_reanchor_and_provenance()
    test_disk_persistence_and_hot_backup()

    print(f"\nSummary: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
