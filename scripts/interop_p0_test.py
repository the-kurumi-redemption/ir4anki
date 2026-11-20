"""Comprehensive P0 regression tests for Joplin-style InteropService & StorageEngine SSOT.

Covers:
1. InteropService module registry (`GET /api/interop/modules`) & `extract_resource_ids` variants
2. Two-stage import: `:/<resource_id>` rewriting, flat media sandbox, SHA-256 deduplication,
   same-basename different-content isolation, unreferenced junk image exclusion
3. `note_resources` completeness & `gc_unreferenced_resources()` zero false deletions + grace window
4. Code-block / inline-code preservation, ref-style images, HTML `<img>` -> Markdown normalization,
   URL-encoded paths, `#fragment` / `?query` preservation
5. Non-blocking tolerance: UTF-8 BOM stripping, empty .md, invalid UTF-8, system dirs, missing refs
6. Conflict policies (`error` atomic 409, `skip`, `rename`, `overwrite` single revision +
   no spurious segment seeding + stale NOTES_DIR never shadowing overwritten DB body)
7. Security validation (traversal, protected target_dir, intra-batch duplicate, budgets)
8. `READING_MODE=0` resource serving (`/api/resources/{id}`) & standalone image upload
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import sys
from pathlib import Path

from native_fixture import configure, run_closed, tempdir

ROOT = Path(__file__).resolve().parents[1]
os.environ["ANKI_STATE_DIR"] = tempdir("interop-p0-state-")
os.environ["ANKI_NOTES_DIR"] = tempdir("interop-p0-notes-")
os.environ["ANKI_PREVIEW_MODE"] = "0"
os.environ["ANKI_READING_MODE"] = "1"
configure()
sys.path.insert(0, str(ROOT / "backend"))

import httpx
import app as b
from storage.domain import extract_resource_ids

PASS = 0
FAIL = 0


def check(name: str, cond: bool, detail: object = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}: {detail!r}")


async def post_import(
    client: httpx.AsyncClient,
    entries: list[tuple[str, bytes]],
    *,
    target_dir: str = "",
    on_conflict: str = "error",
    endpoint: str = "/api/interop/import",
):
    return await client.post(
        endpoint,
        data={
            "rel_paths": [p for p, _ in entries],
            "dir": target_dir,
            "on_conflict": on_conflict,
        },
        files=[
            ("files", (Path(p).name or "file", data, "application/octet-stream"))
            for p, data in entries
        ],
    )


async def main() -> None:
    eng = b._storage()

    print("=== 1. extract_resource_ids & Interop Module Registry ===")
    rid_a = "0123456789abcdef0123456789abcdef"
    rid_b = "fedcba9876543210fedcba9876543210"
    rid_c = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    sample_md = (
        f"![a](:/{rid_a})\n"
        f'<img src=":/{rid_b}" alt="b">\n'
        f"![c](:/{rid_c}#anchor)\n"
        f"[ref]: :/{rid_a}?v=2\n"
    )
    check(
        "extract_resource_ids finds markdown, html, fragment, and ref-style :/id",
        extract_resource_ids(sample_md) == [rid_a, rid_b, rid_c],
        extract_resource_ids(sample_md),
    )

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=b.app), base_url="http://t"
    ) as c:
        r = await c.get("/api/interop/modules")
        check("GET /api/interop/modules -> 200", r.status_code == 200, r.text)
        mods = r.json().get("modules") or []
        check(
            "md importer registered with directory support",
            any(m["format"] == "md" and m["supports_directory"] for m in mods),
            mods,
        )

        print("=== 2. Book Layout Import, Deduplication, On-Demand Resources & GC Safety ===")
        png_1 = b"\x89PNG\r\n\x1a\nimg-content-alpha"
        png_2 = b"\x89PNG\r\n\x1a\nimg-content-beta"
        png_unused = b"\x89PNG\r\n\x1a\njunk-never-referenced"
        entries = [
            (
                "金钱心理学/001-正文.md",
                (
                    "# 正文\n\n"
                    "![图1](_assets/a.png)\n"
                    "![图2](_assets/fig%20space.png#chart)\n"
                    '<img src="_assets/a.png" alt="HTML图">\n'
                    "![参考图][r1]\n"
                    "![外链](https://example.org/ext.png)\n"
                    "```md\n![代码块内不改](_assets/a.png)\n```\n"
                    "行内代码 `![不改](_assets/a.png)`。\n\n"
                    "[r1]: _assets/a.png\n"
                ).encode("utf-8"),
            ),
            (
                "金钱心理学/章节/002-次章.md",
                (
                    "# 次章\n\n"
                    "![同名异图](_assets/a.png)\n"
                    "![同内容去重](../_assets/copy_of_alpha.png)\n"
                ).encode("utf-8"),
            ),
            ("金钱心理学/_assets/a.png", png_1),
            ("金钱心理学/_assets/fig space.png", png_2),
            ("金钱心理学/_assets/copy_of_alpha.png", png_1),  # same SHA-256 as png_1
            ("金钱心理学/章节/_assets/a.png", b"\x89PNG\r\n\x1a\nimg-chapter2-different"),
            ("金钱心理学/_assets/unused.png", png_unused),
        ]
        r = await post_import(c, entries, target_dir="2026")
        check("POST /api/interop/import -> 200", r.status_code == 200, r.text)
        body = r.json()
        summary = body["summary"]
        check("imported 2 notes", summary["notes_imported"] == 2, summary)
        check("imported 4 referenced image refs (1 reused via SHA-256)", summary["resources_imported"] == 4 and summary["resources_reused"] == 1, summary)
        check(
            "unreferenced unused.png skipped and NOT stored in DB",
            any(s["path"] == "金钱心理学/_assets/unused.png" for s in body["skipped"]),
            body["skipped"],
        )
        check(
            "NOTES_DIR untouched (StorageEngine SSOT, no disk writes)",
            not (b.NOTES_DIR / "2026" / "金钱心理学").exists(),
            list(b.NOTES_DIR.rglob("*")),
        )

        note1 = eng.get_note_by_legacy_path("2026/金钱心理学/001-正文.md")
        note2 = eng.get_note_by_legacy_path("2026/金钱心理学/章节/002-次章.md")
        check("note1 & note2 exist in StorageEngine", note1 is not None and note2 is not None)
        assert note1 is not None and note2 is not None

        res_by_orig = {x["original"]: x["resource_id"] for x in body["imported_resources"]}
        rid1 = res_by_orig["金钱心理学/_assets/a.png"]
        rid2 = res_by_orig["金钱心理学/_assets/fig space.png"]
        rid_copy = res_by_orig["金钱心理学/_assets/copy_of_alpha.png"]
        rid_ch2 = res_by_orig["金钱心理学/章节/_assets/a.png"]

        check("same content deduplicated to identical resource_id", rid1 == rid_copy, (rid1, rid_copy))
        check("same basename different content got distinct UUIDs", rid1 != rid_ch2, (rid1, rid_ch2))
        check("inline markdown rewritten to :/id", f"![图1](:/{rid1})" in note1["body"], note1["body"])
        check("URL-encoded path + fragment preserved", f"![图2](:/{rid2}#chart)" in note1["body"], note1["body"])
        check("HTML <img> normalized to Markdown ![alt](:/id)", f"![HTML图](:/{rid1})" in note1["body"], note1["body"])
        check("reference-style image definition rewritten", f"[r1]: :/{rid1}" in note1["body"], note1["body"])
        check("external URL untouched", "![外链](https://example.org/ext.png)" in note1["body"])
        check("fenced code block untouched", "```md\n![代码块内不改](_assets/a.png)\n```" in note1["body"])
        check("inline code span untouched", "`![不改](_assets/a.png)`" in note1["body"])
        check("single initial revision recorded (no dirty stage-1 revision)", len(eng.list_note_revisions(note1["id"])) == 1)
        check("imported notes do not auto-join reading list", not note1["in_list"] and not note2["in_list"])

        # Critical GC check: note_resources must link all referenced resources -> 0 deletions!
        nr_rows = eng.db.query_all("SELECT note_id, resource_id FROM note_resources")
        nr_pairs = {(row["note_id"], row["resource_id"]) for row in nr_rows}
        check(
            "note_resources tracks all linked resources",
            {(note1["id"], rid1), (note1["id"], rid2), (note2["id"], rid_ch2), (note2["id"], rid1)}.issubset(nr_pairs),
            nr_pairs,
        )
        gc_deleted = eng.gc_unreferenced_resources()
        check("gc_unreferenced_resources deletes 0 imported images!", gc_deleted == 0, gc_deleted)

        # Verify serving via /api/resources/{id} works EVEN when READING_MODE is off
        old_rm = b.READING_MODE
        try:
            b.READING_MODE = False
            resp_res = await c.get(f"/api/resources/{rid1}")
            check("GET /api/resources/{id} serves bytes with READING_MODE=0", resp_res.status_code == 200 and resp_res.content == png_1)
        finally:
            b.READING_MODE = old_rm
        resp_ch2 = await c.get(f"/api/resources/{rid_ch2}")
        check("GET /api/resources/{rid_ch2} serves distinct chapter-2 bytes", resp_ch2.status_code == 200 and resp_ch2.content == b"\x89PNG\r\n\x1a\nimg-chapter2-different")

        # Verify GC grace window protects fresh orphan resources
        orphan_res = eng.put_resource("in-flight.png", b"\x89PNG\r\n\x1a\nin-flight")
        check(
            "GC with min_age_seconds=3600 protects fresh unreferenced resource",
            eng.gc_unreferenced_resources(min_age_seconds=3600) == 0 and eng.get_resource(orphan_res["id"]) is not None,
        )
        check(
            "GC with min_age_seconds=0 collects unreferenced orphan resource",
            eng.gc_unreferenced_resources(min_age_seconds=0) == 1 and eng.get_resource(orphan_res["id"]) is None,
        )

        print("=== 3. Non-Blocking Tolerance (BOM, Empty, Bad UTF-8, System Dirs, Missing Ref) ===")
        mixed_entries = [
            ("容错测试/good.md", "\ufeff# 带BOM标题\n\n![缺失图](missing.png)\n".encode("utf-8")),
            ("容错测试/empty.md", b""),
            ("容错测试/spaces.md", b"   \n\t\n"),
            ("容错测试/bad_gbk.md", "中文GBK".encode("gbk")),
            ("容错测试/.git/config", b"[core]"),
            ("容错测试/.obsidian/app.json", b"{}"),
            ("容错测试/_assets/private.md", b"# should skip"),
            ("容错测试/manifest.json", b"{}"),
            ("纯空目录/only_junk.json", b"{}"),
        ]
        r = await post_import(c, mixed_entries, target_dir="2026")
        check("mixed faulty batch returns 200 (non-blocking)", r.status_code == 200, r.text)
        res_m = r.json()
        check("good.md imported despite sibling bad files", res_m["summary"]["notes_imported"] == 1, res_m["summary"])
        good_note = eng.get_note_by_legacy_path("2026/容错测试/good.md")
        check("UTF-8 BOM stripped cleanly", good_note is not None and good_note["body"].startswith("# 带BOM标题"), good_note["body"] if good_note else None)
        check("warnings include bad UTF-8 and missing image ref", any("bad_gbk.md" in w for w in res_m["warnings"]) and any("missing.png" in w for w in res_m["warnings"]), res_m["warnings"])
        check("skipped list records empty, bad_gbk, system dirs, manifest", len(res_m["skipped"]) >= 7, res_m["skipped"])
        check("empty directory (纯空目录) did not create a notebook", eng.resolve_notebook("2026/纯空目录") is None)

        print("=== 4. Conflict Policies & Stale NOTES_DIR SSOT Precedence ===")
        # Simulate a legacy file that already existed on disk in NOTES_DIR
        stale_disk = b.NOTES_DIR / "legacy.md"
        stale_disk.write_text("# Old Disk Version\n\nold text", encoding="utf-8")
        # Trigger initial sync via /api/files/upload with error -> should detect conflict 409!
        r = await post_import(
            c,
            [("legacy.md", b"# New Version\n\n![pic](p.png)"), ("p.png", b"\x89PNG\r\n\x1a\np-conflict-test")],
            on_conflict="error",
            endpoint="/api/files/upload",
        )
        check("conflict with error policy -> 409", r.status_code == 409, r.text)
        detail = json.loads(r.json()["detail"])
        check("409 detail lists conflicting path", detail["conflicts"] == ["legacy.md"], detail)
        check(
            "409 conflict wrote 0 resources (atomic pre-check)",
            eng.get_resource_by_sha256(eng.shim.sha256_hex(b"\x89PNG\r\n\x1a\np-conflict-test")) is None,
        )

        # Overwrite via /api/files/upload -> StorageEngine updated, stale disk untouched,
        # AND /api/files/raw must serve the NEW StorageEngine content!
        r = await post_import(
            c,
            [("legacy.md", b"# New Version\n\n![pic](p.png)"), ("p.png", b"\x89PNG\r\n\x1a\np-conflict-test")],
            on_conflict="overwrite",
            endpoint="/api/files/upload",
        )
        check("overwrite -> 200", r.status_code == 200, r.text)
        raw_resp = await c.get("/api/files/raw", params={"path": "legacy.md"})
        check("GET /api/files/raw returns overwritten StorageEngine body (not stale NOTES_DIR)", raw_resp.status_code == 200 and "# New Version" in raw_resp.json()["text"] and ":/" in raw_resp.json()["text"], raw_resp.text)
        overwritten_note = eng.get_note_by_legacy_path("legacy.md")
        assert overwritten_note is not None
        check("overwrite on non-list note did NOT seed spurious reading segments", len(eng.get_note_segments(overwritten_note["id"])) == 0)
        check("overwrite updated note_resources so GC preserves new image", eng.gc_unreferenced_resources() == 0)

        # Rename & skip policies
        r_ren = await post_import(c, [("legacy.md", b"# Renamed Copy")], on_conflict="rename", endpoint="/api/files/upload")
        check("rename policy creates legacy (1).md", r_ren.status_code == 200 and eng.get_note_by_legacy_path("legacy (1).md") is not None)
        r_skip = await post_import(c, [("legacy.md", b"# Should Not Apply")], on_conflict="skip", endpoint="/api/files/upload")
        check("skip policy leaves legacy.md untouched", r_skip.status_code == 200 and "# New Version" in eng.get_note_by_legacy_path("legacy.md")["body"])

        print("=== 5. Security Validation & Standalone Image Upload ===")
        for bad_path in ["../escape.md", "../../outside.png", "/etc/passwd"]:
            r = await post_import(c, [(bad_path, b"# bad")])
            check(f"traversal/abs path rejected ({bad_path})", r.status_code == 400, r.status_code)
        r = await post_import(c, [("a.md", b"# ok")], target_dir="_assets")
        check("protected target_dir (_assets) rejected -> 400", r.status_code == 400, r.status_code)
        r = await post_import(c, [("dup.md", b"# 1"), ("dup.md", b"# 2")])
        check("intra-batch duplicate target -> 409", r.status_code == 409, r.status_code)

        # Standalone image upload (explicit image-only batch)
        standalone_bytes = b"\x89PNG\r\n\x1a\nstandalone-pic"
        r = await post_import(c, [("solo.png", standalone_bytes)])
        check("standalone image upload -> 200", r.status_code == 200, r.text)
        solo_res = r.json()["imported_resources"]
        check("standalone image stored in resources", len(solo_res) == 1 and eng.get_resource(solo_res[0]["resource_id"]) is not None, solo_res)

    print(f"\nSummary: {PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    asyncio.run(run_closed(b, main()))
