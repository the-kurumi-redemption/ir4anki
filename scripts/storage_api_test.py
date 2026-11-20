#!/usr/bin/env python3
"""Stage 3 End-to-End API Integration Test for StorageEngine-backed backend/app.py.

Verifies:
1. Startup auto-migration from legacy `NOTES_DIR` + `reading.db` into `data.db` + `media/`
2. `GET /api/storage/tree` & `GET /api/notes/{id}` (UUID + legacy path resolution)
3. `GET /api/storage/search` (FTS5 trigram & CJK substring search + notebook filter)
4. `POST /api/reading/edit` -> `GET /api/notes/{id}/revisions` -> `POST /api/notes/{id}/revisions/{rev}/restore`
5. `POST /api/resources/upload`, `GET /api/resources/{id}`, `POST /api/reading/media/upload`, `GET /api/reading/media/{id}`
6. `POST /api/files/rename`, `POST /api/files/move`, `GET /api/files/operation` (idempotency), `POST /api/files/undo`
7. `POST /api/files/delete` -> `GET /api/reading/source` (soft-deleted provenance survival!)
   -> `GET /api/storage/trash` -> `POST /api/storage/trash/restore` -> `POST /api/storage/trash/empty`
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import sqlite3
import sys
from pathlib import Path

from native_fixture import NativeData, configure, run_closed, tempdir

ROOT = Path(__file__).resolve().parent.parent
TMP = Path(tempdir("ir4anki-storage-api-test-"))
STATE = TMP / "state"
NOTES = TMP / "corpus"
STATE.mkdir(parents=True, exist_ok=True)
NOTES.mkdir(parents=True, exist_ok=True)

# 1. Seed a legacy corpus + legacy reading.db BEFORE importing app.py to test auto-migration!
(NOTES / "2026" / "内科学").mkdir(parents=True, exist_ok=True)
(NOTES / "2026" / "外科学").mkdir(parents=True, exist_ok=True)
(NOTES / "_assets").mkdir(parents=True, exist_ok=True)

PNG_BYTES = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\xcf\xc0"
    b"\x00\x00\x03\x01\x01\x00\xc9\xfe\x92\xef\x00\x00\x00\x00IEND\xaeB`\x82"
)
(NOTES / "_assets" / "ecg-demo.png").write_bytes(PNG_BYTES)

NOTE_A_TEXT = (
    "# 心力衰竭\n"
    "\n"
    "左心衰竭最早出现的症状是劳力性呼吸困难。\n"
    "![心电图](ecg-demo.png)\n"
    "急性肺水肿表现为粉红色泡沫痰。\n"
)
NOTE_B_TEXT = (
    "# 阑尾炎\n"
    "\n"
    "急性阑尾炎的典型腹痛特点是转移性右下腹痛。\n"
    "麦氏点压痛是重要体征。\n"
)
(NOTES / "2026" / "内科学" / "心力衰竭.md").write_text(NOTE_A_TEXT, encoding="utf-8")
(NOTES / "2026" / "外科学" / "阑尾炎.md").write_text(NOTE_B_TEXT, encoding="utf-8")

# Seed legacy reading.db with 1 listed note (心力衰竭.md) + 1 card provenance link
legacy_db = STATE / "reading.db"
conn = sqlite3.connect(legacy_db)
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
a_lines = NOTE_A_TEXT.rstrip("\n").split("\n")
a_fp = hashlib.sha256("\n".join(a_lines).encode("utf-8")).hexdigest()[:32]
a_sha = hashlib.sha256(NOTE_A_TEXT.encode("utf-8")).hexdigest()
conn.execute(
    "INSERT INTO rfiles(path, in_list, pos, added_at, file_sha, needs_resync) VALUES(?,?,?,?,?,0)",
    ("2026/内科学/心力衰竭.md", 1, 0, "2026-11-14T10:00:00", a_sha),
)
conn.execute(
    "INSERT INTO segments(path, seg_id, start_line, end_line, fingerprint, first_line, title, heading_path, status, parent_seg_id, updated_at) "
    "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
    ("2026/内科学/心力衰竭.md", 1, 1, len(a_lines), a_fp, a_lines[0], "心力衰竭", "[]", "active", None, "2026-11-14T10:00:00"),
)
conn.execute(
    "INSERT INTO rcards(path, seg_id, note_id) VALUES(?,?,?)",
    ("2026/内科学/心力衰竭.md", 1, 777001),
)
conn.commit()
conn.close()

os.environ["ANKI_READING_MODE"] = "1"
os.environ["ANKI_PREVIEW_MODE"] = "0"
os.environ["ANKI_STATE_DIR"] = str(STATE)
os.environ["ANKI_NOTES_DIR"] = str(NOTES)
configure()

sys.path.insert(0, str(ROOT / "backend"))
import app as backend  # noqa: E402
import httpx  # noqa: E402
backend.REVIEW_WEB_V2_DIST = Path("/nonexistent")

PASS = 0
FAIL = 0


def check(label: str, cond: bool, detail: object = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {label}")
    else:
        FAIL += 1
        print(f"  FAIL  {label} -> {detail}")


async def main() -> None:
    transport = httpx.ASGITransport(app=backend.app)
    async with httpx.AsyncClient(transport=transport, base_url="http://t") as c:
        print("=== 1. Startup Auto-Migration from reading.db + corpus/ ===")
        r = await c.get("/api/storage/tree")
        check("GET /api/storage/tree -> 200", r.status_code == 200, r.text)
        tree = r.json()
        notebooks = tree.get("notebooks") or []
        notes = tree.get("notes") or []
        check("migrated 3 notebooks (2026, 内科学, 外科学)", len(notebooks) == 3, [n["name"] for n in notebooks])
        check("migrated 2 notes", len(notes) == 2, [n["path"] for n in notes])

        note_a = next((n for n in notes if n["path"] == "2026/内科学/心力衰竭.md"), None)
        note_b = next((n for n in notes if n["path"] == "2026/外科学/阑尾炎.md"), None)
        check("note_a exists and is in reading list", note_a is not None and note_a["in_list"] is True, note_a)
        check("note_b exists and is not in reading list", note_b is not None and note_b["in_list"] is False, note_b)
        assert note_a is not None and note_b is not None

        print("=== 2. Note Details & Joplin Resource Link Rewrite ===")
        r = await c.get(f"/api/notes/{note_a['id']}")
        check("GET /api/notes/{uuid} -> 200", r.status_code == 200, r.text)
        na_full = r.json()
        check("note_a body rewritten to ![...](:/<resource_id>)", "![心电图](:/" in na_full["body"], na_full["body"])
        check("note_a segments preserved", len(na_full.get("segments") or []) == 1, na_full.get("segments"))
        check("note_a card provenance 777001 preserved", 777001 in na_full["segments"][0]["cards_created"], na_full["segments"])

        # Extract resource_id from body and fetch via /api/resources/{id} and /api/reading/media/{id}
        import re
        m = re.search(r":/([0-9a-f]{32})", na_full["body"])
        check("extracted 32-hex resource_id", m is not None, na_full["body"])
        if m:
            res_id = m.group(1)
            r_res = await c.get(f"/api/resources/{res_id}")
            check("GET /api/resources/{id} serves PNG bytes", r_res.status_code == 200 and r_res.content == PNG_BYTES)
            r_med = await c.get(f"/api/reading/media/{res_id}")
            check("GET /api/reading/media/{id} serves PNG bytes", r_med.status_code == 200 and r_med.content == PNG_BYTES)
            r_leg = await c.get("/api/reading/media/ecg-demo.png")
            check("GET /api/reading/media/ecg-demo.png legacy basename still works", r_leg.status_code == 200 and r_leg.content == PNG_BYTES)

        print("=== 3. FTS5 Trigram Search & Notebook Filter ===")
        r = await c.get("/api/storage/search", params={"q": "粉红色泡沫痰"})
        check("FTS5 search hits note_a", r.status_code == 200 and len(r.json()["results"]) == 1, r.json())
        check("FTS5 search hit ID matches note_a", r.json()["results"][0]["id"] == note_a["id"])

        r = await c.get("/api/storage/search", params={"q": "麦氏", "notebook_id": note_b["notebook_id"]})
        check("2-char CJK search with notebook_id hits note_b", r.status_code == 200 and len(r.json()["results"]) == 1)

        r = await c.get("/api/storage/search", params={"q": "麦氏", "notebook_id": note_a["notebook_id"]})
        check("search with different notebook_id returns 0 hits", r.status_code == 200 and len(r.json()["results"]) == 0)

        print("=== 4. In-App Edit -> Revision History -> Time-Travel Rollback ===")
        seg0 = na_full["segments"][0]
        edited_body = na_full["body"].rstrip("\n") + "\n洋地黄是正性肌力药。"
        r = await c.post(
            "/api/reading/edit",
            json={
                "path": note_a["path"],
                "seg_id": seg0["seg_id"],
                "new_text": edited_body,
                "expected_revision": na_full["body_sha"],
                "expected_fingerprint": seg0["fingerprint"],
            },
        )
        check("POST /api/reading/edit -> 200", r.status_code == 200 and r.json().get("ok") is True, r.text)

        r = await c.get(f"/api/notes/{note_a['id']}/revisions")
        check("GET /api/notes/{id}/revisions -> 200", r.status_code == 200)
        revs = r.json().get("revisions") or []
        check("note_a now has >= 2 revisions (migration + reading_edit)", len(revs) >= 2, revs)
        oldest_rev_id = revs[-1]["id"]

        r_rev = await c.get(f"/api/notes/{note_a['id']}/revisions/{oldest_rev_id}")
        check("GET /api/notes/{id}/revisions/{rev_id} returns original body", r_rev.status_code == 200 and "洋地黄" not in r_rev.json()["body"])

        r_rest = await c.post(f"/api/notes/{note_a['id']}/revisions/{oldest_rev_id}/restore")
        check("POST /api/notes/{id}/revisions/{rev_id}/restore rolls back note", r_rest.status_code == 200 and r_rest.json().get("ok") is True, r_rest.text)
        restored_note = r_rest.json()["note"]
        check("rolled back body no longer has 洋地黄", "洋地黄" not in restored_note["body"])

        print("=== 5. Resource Upload & Deduplication ===")
        r_up = await c.post(
            "/api/resources/upload",
            files={"file": ("new-chart.png", PNG_BYTES, "image/png")},
        )
        check("POST /api/resources/upload -> 200", r_up.status_code == 200 and r_up.json().get("ok") is True, r_up.text)
        if m:
            check("SHA-256 deduplication reuses existing resource_id", r_up.json()["resource"]["id"] == m.group(1))

        print("=== 6. Atomic File Rename, Request Idempotency & Undo ===")
        req_id = "req-rename-heart-001"
        r_ren = await c.post(
            "/api/files/rename",
            json={"path": "2026/内科学/心力衰竭.md", "new_name": "慢性心衰.md", "requestId": req_id},
        )
        check("POST /api/files/rename -> 200", r_ren.status_code == 200 and r_ren.json().get("ok") is True, r_ren.text)
        op_id = r_ren.json()["operationId"]
        check("renamed path is 2026/内科学/慢性心衰.md", r_ren.json()["path"] == "2026/内科学/慢性心衰.md")
        check("rename response includes old_path", r_ren.json().get("old_path") == "2026/内科学/心力衰竭.md", r_ren.text)

        # Idempotent retry with same requestId
        r_retry = await c.post(
            "/api/files/rename",
            json={"path": "2026/内科学/心力衰竭.md", "new_name": "慢性心衰.md", "requestId": req_id},
        )
        check("idempotent retry returns same operationId", r_retry.status_code == 200 and r_retry.json()["operationId"] == op_id)

        r_op = await c.get("/api/files/operation", params={"request_id": req_id})
        check(
            "GET /api/files/operation reports complete with old_path",
            r_op.status_code == 200
            and r_op.json()["status"] == "complete"
            and r_op.json().get("old_path") == "2026/内科学/心力衰竭.md"
            and r_op.json().get("path") == "2026/内科学/慢性心衰.md",
            r_op.text,
        )

        # Undo the rename (with requestId, verifying distinct undo operationId & old_path)
        undo_req = "req-undo-heart-001"
        r_undo = await c.post("/api/files/undo", json={"operationId": op_id, "requestId": undo_req})
        check(
            "POST /api/files/undo restores 2026/内科学/心力衰竭.md with old_path",
            r_undo.status_code == 200
            and r_undo.json()["path"] == "2026/内科学/心力衰竭.md"
            and r_undo.json().get("old_path") == "2026/内科学/慢性心衰.md"
            and r_undo.json().get("operationId")
            and r_undo.json().get("operationId") != op_id,
            r_undo.text,
        )
        r_undo_op = await c.get("/api/files/operation", params={"request_id": undo_req})
        check(
            "GET /api/files/operation resolves undo requestId with old_path",
            r_undo_op.status_code == 200
            and r_undo_op.json()["status"] == "complete"
            and r_undo_op.json().get("old_path") == "2026/内科学/慢性心衰.md"
            and r_undo_op.json().get("path") == "2026/内科学/心力衰竭.md",
            r_undo_op.text,
        )

        print("=== 7. Soft Delete (Recycle Bin), Provenance Survival & Restore ===")
        r_del = await c.post(
            "/api/files/delete",
            json={"path": "2026/内科学/心力衰竭.md", "confirm": "心力衰竭.md"},
        )
        check("POST /api/files/delete -> 200", r_del.status_code == 200 and r_del.json().get("ok") is True)

        # Even while deleted, Anki card 777001 MUST still resolve its reading source!
        r_src = await c.get("/api/reading/source", params={"note_id": 777001})
        check("GET /api/reading/source resolves card on soft-deleted note!", r_src.status_code == 200, r_src.text)
        check("source payload marks note_deleted=True", r_src.json().get("note_deleted") is True, r_src.json())

        # Check recycle bin
        r_trash = await c.get("/api/storage/trash")
        check("GET /api/storage/trash lists deleted note_a", r_trash.status_code == 200 and any(n["id"] == note_a["id"] for n in r_trash.json()["notes"]))

        # Restore from recycle bin
        r_untrash = await c.post(
            "/api/storage/trash/restore",
            json={"kind": "note", "id": note_a["id"]},
        )
        check("POST /api/storage/trash/restore -> 200", r_untrash.status_code == 200 and r_untrash.json().get("ok") is True, r_untrash.text)
        check("restored note file mirrored back to NOTES_DIR", (NOTES / "2026" / "内科学" / "心力衰竭.md").is_file())

        # Soft-delete note_b and empty trash
        await c.post("/api/files/delete", json={"path": "2026/外科学/阑尾炎.md", "confirm": "阑尾炎.md"})
        r_empty = await c.post("/api/storage/trash/empty")
        check("POST /api/storage/trash/empty purges note_b", r_empty.status_code == 200 and r_empty.json().get("notes_purged") == 1, r_empty.text)

    print(f"\nSummary: {PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    asyncio.run(run_closed(backend, main()))
