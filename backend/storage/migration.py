"""Stage 2 Migration Tool: Legacy `~/anki-notes` + `reading.db` -> Joplin-mode `StorageEngine`.

Safely and idempotently migrates:
1. Directory hierarchy under `NOTES_DIR` (excluding protected/system directories like `_assets`, `.git`, `.obsidian`) into `notebooks` UUID tree.
2. Image assets (`_assets/` and nested book images) into flat `media/<resource_id>.<ext>` sandbox with SHA-256 deduplication and `resources` metadata.
3. Markdown files (`.md`) into `notes` and initial `note_revisions`, rewriting local image links `![alt](_assets/foo.png)` -> `![alt](:/<resource_id>)` and populating `note_resources`.
4. Progressive reading progress from `reading.db` (`rfiles`, `segments`, `rcards`, `rorphans`, `rround`):
   - Preserves `in_list`, `list_pos`, `added_at`, `needs_resync`.
   - Recomputes `fingerprint` and `first_line` on the rewritten Markdown lines so `(:/<resource_id>)` link updates never falsely trip the external-drift fuse!
   - Migrates deleted/missing historical `rfiles` rows as soft-deleted notes (`deleted_at` set) so historical `rcards` Anki card provenance is 100% preserved.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
from pathlib import Path
from typing import Any

from .domain import (
    infer_note_title,
    normalize_newlines,
    seed_whole_note,
    seg_fingerprint,
)
from .engine import StorageEngine

SKIP_DIRS = {".git", ".obsidian", ".trash", "node_modules", "__pycache__", "_assets"}
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".avif"}
MD_IMAGE_RE = re.compile(r"!\[([^\]]*)\]\(([^)]+)\)")


class LegacyMigrator:
    """Migrates a legacy `NOTES_DIR` corpus and `reading.db` into `StorageEngine`."""

    def __init__(
        self,
        engine: StorageEngine,
        notes_dir: str | Path,
        reading_db_path: str | Path | None = None,
    ) -> None:
        self.engine = engine
        self.notes_dir = Path(notes_dir).resolve()
        self.reading_db_path = Path(reading_db_path).resolve() if reading_db_path else None

        # Lookup caches built during image discovery
        self._images_by_rel: dict[str, Path] = {}
        self._images_by_basename: dict[str, list[Path]] = {}
        self._resource_by_path: dict[Path, dict[str, Any]] = {}

    def _index_corpus_images(self) -> int:
        """Scan `notes_dir` for all image files (including inside `_assets`) to build resolution maps."""
        self._images_by_rel.clear()
        self._images_by_basename.clear()
        if not self.notes_dir.is_dir():
            return 0
        count = 0
        non_asset_skip = SKIP_DIRS - {"_assets"}
        for p in sorted(self.notes_dir.rglob("*")):
            if not p.is_file():
                continue
            rel = p.relative_to(self.notes_dir)
            if any(part in non_asset_skip for part in rel.parts):
                continue
            if p.suffix.lower() in IMAGE_EXTS:
                rel_posix = rel.as_posix()
                self._images_by_rel[rel_posix] = p.resolve()
                self._images_by_basename.setdefault(p.name, []).append(p.resolve())
                count += 1
        return count

    def _resolve_image_path(self, md_file_path: Path, raw_target: str) -> Path | None:
        """Resolve a Markdown image target relative to `md_file_path`, `notes_dir/_assets`, or basename."""
        target = raw_target.strip()
        if not target:
            return None
        # Strip optional markdown title: ![alt](path "title")
        if target.startswith("<") and ">" in target:
            target = target[1 : target.index(">")]
        else:
            target = target.split()[0]

        if target.startswith(("http://", "https://", "data:", ":/")):
            return None

        # 1. Relative to the markdown file's parent directory
        try:
            cand = (md_file_path.parent / target).resolve()
            if cand.is_file() and cand.is_relative_to(self.notes_dir):
                return cand
        except OSError:
            pass

        # 2. Root _assets/<basename>
        bname = os.path.basename(target)
        if not bname:
            return None
        root_asset = (self.notes_dir / "_assets" / bname).resolve()
        if root_asset.is_file() and root_asset.is_relative_to(self.notes_dir):
            return root_asset

        # 3. Corpus-wide basename match
        hits = self._images_by_basename.get(bname)
        if hits:
            return hits[0]
        return None

    def _ensure_resource_imported(self, img_path: Path) -> dict[str, Any]:
        """Import `img_path` into `StorageEngine` resources sandbox (cached by resolved path)."""
        resolved = img_path.resolve()
        if resolved in self._resource_by_path:
            return self._resource_by_path[resolved]
        data = resolved.read_bytes()
        rel_name = resolved.relative_to(self.notes_dir).as_posix()
        res = self.engine.put_resource(
            resolved.name,
            data,
            deduplicate=True,
            legacy_name=rel_name,
        )
        self._resource_by_path[resolved] = res
        return res

    def _rewrite_markdown_images(
        self, md_file_path: Path, text: str
    ) -> tuple[str, int, list[str]]:
        """Rewrite local Markdown image links `![alt](target)` -> `![alt](:/<resource_id>)`.

        Returns `(rewritten_text, rewritten_count, unresolved_targets)`.
        """
        rewritten_count = 0
        unresolved: list[str] = []

        def _replace(match: re.Match[str]) -> str:
            nonlocal rewritten_count
            alt = match.group(1)
            raw_target = match.group(2)
            stripped = raw_target.strip()
            if stripped.startswith(("http://", "https://", "data:", ":/")):
                return match.group(0)
            img_path = self._resolve_image_path(md_file_path, raw_target)
            if img_path is None:
                unresolved.append(raw_target)
                return match.group(0)
            res = self._ensure_resource_imported(img_path)
            rewritten_count += 1
            return f"![{alt}](:/{res['id']})"

        new_text = MD_IMAGE_RE.sub(_replace, text)
        return new_text, rewritten_count, unresolved

    def _load_legacy_reading_db(self) -> dict[str, Any]:
        """Read all state from legacy `reading.db` if present."""
        empty = {
            "rfiles": {},
            "segments": {},
            "rcards": {},
            "rorphans": {},
            "rround": None,
        }
        if not self.reading_db_path or not self.reading_db_path.is_file():
            return empty

        conn = sqlite3.connect(f"{self.reading_db_path.as_uri()}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        try:
            tables = {
                r["name"]
                for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                ).fetchall()
            }
            rfiles: dict[str, dict[str, Any]] = {}
            if "rfiles" in tables:
                cols = {r[1] for r in conn.execute("PRAGMA table_info(rfiles)")}
                has_resync = "needs_resync" in cols
                sql = (
                    "SELECT path, in_list, pos, added_at, file_sha, needs_resync FROM rfiles"
                    if has_resync
                    else "SELECT path, in_list, pos, added_at, file_sha, 0 AS needs_resync FROM rfiles"
                )
                for r in conn.execute(sql):
                    rfiles[r["path"]] = dict(r)

            rcards: dict[tuple[str, int], list[int]] = {}
            if "rcards" in tables:
                for r in conn.execute(
                    "SELECT path, seg_id, note_id FROM rcards ORDER BY rowid ASC"
                ):
                    rcards.setdefault((r["path"], int(r["seg_id"])), []).append(
                        int(r["note_id"])
                    )

            segments: dict[str, list[dict[str, Any]]] = {}
            if "segments" in tables:
                for r in conn.execute(
                    "SELECT path, seg_id, start_line, end_line, fingerprint, first_line, "
                    "title, heading_path, status, parent_seg_id, updated_at "
                    "FROM segments ORDER BY path, start_line, seg_id"
                ):
                    path = r["path"]
                    sid = int(r["seg_id"])
                    try:
                        hp = json.loads(r["heading_path"]) if r["heading_path"] else []
                    except Exception:
                        hp = []
                    segments.setdefault(path, []).append(
                        {
                            "seg_id": sid,
                            "start_line": int(r["start_line"]),
                            "end_line": int(r["end_line"]),
                            "fingerprint": r["fingerprint"] or "",
                            "first_line": r["first_line"] or "",
                            "title": r["title"] or "",
                            "heading_path": hp,
                            "status": r["status"] or "todo",
                            "parent_seg_id": r["parent_seg_id"],
                            "stale": False,
                            "updated_at": r["updated_at"],
                            "cards_created": rcards.get((path, sid), []),
                        }
                    )

            rorphans: dict[str, list[dict[str, Any]]] = {}
            if "rorphans" in tables:
                for r in conn.execute(
                    "SELECT path, chunk_key, data FROM rorphans ORDER BY rowid ASC"
                ):
                    try:
                        payload = json.loads(r["data"]) if r["data"] else {}
                    except Exception:
                        payload = {}
                    rorphans.setdefault(r["path"], []).append(
                        {"chunk_key": r["chunk_key"], **payload}
                    )

            rround: dict[str, Any] | None = None
            if "rround" in tables:
                row = conn.execute("SELECT data FROM rround WHERE id = 1").fetchone()
                if row and row["data"]:
                    try:
                        parsed = json.loads(row["data"])
                        if isinstance(parsed, dict):
                            rround = parsed
                    except Exception:
                        pass

            return {
                "rfiles": rfiles,
                "segments": segments,
                "rcards": rcards,
                "rorphans": rorphans,
                "rround": rround,
            }
        finally:
            conn.close()

    def run(self, *, import_unreferenced_assets: bool = False) -> dict[str, Any]:
        """Execute full migration into `self.engine` and return detailed verification report."""
        indexed_images = self._index_corpus_images()
        legacy_db = self._load_legacy_reading_db()
        rfiles = legacy_db["rfiles"]
        legacy_segs = legacy_db["segments"]
        legacy_orphans = legacy_db["rorphans"]

        md_files: list[tuple[str, Path]] = []
        if self.notes_dir.is_dir():
            for p in sorted(self.notes_dir.rglob("*.md")):
                if not p.is_file():
                    continue
                rel = p.relative_to(self.notes_dir)
                if any(part in SKIP_DIRS for part in rel.parts):
                    continue
                try:
                    if p.stat().st_size == 0:
                        continue
                except OSError:
                    continue
                md_files.append((rel.as_posix(), p))

        notes_migrated = 0
        archived_missing_migrated = 0
        total_links_rewritten = 0
        unresolved_links: list[dict[str, str]] = []
        total_segments_migrated = 0
        total_cards_migrated = 0
        path_to_note_id: dict[str, str] = {}

        # 1. Migrate all live .md files on disk
        for rel_posix, p in md_files:
            raw_text = normalize_newlines(p.read_text(encoding="utf-8"))
            rewritten_text, link_count, unres = self._rewrite_markdown_images(p, raw_text)
            total_links_rewritten += link_count
            for u in unres:
                unresolved_links.append({"path": rel_posix, "target": u})

            rel_parent = Path(rel_posix).parent.as_posix()
            notebook_id = (
                self.engine.resolve_or_create_notebook_path(rel_parent)
                if rel_parent != "."
                else None
            )

            lines = rewritten_text.split("\n")
            title = Path(rel_posix).stem or infer_note_title(lines, rel_posix)

            rf = rfiles.get(rel_posix)
            in_list = bool(rf["in_list"]) if rf else False
            list_pos = int(rf["pos"]) if rf else 0
            added_at = (rf["added_at"] if in_list else "__archived__") if rf else None
            needs_resync = bool(rf["needs_resync"]) if rf else False

            # Check if already migrated (idempotency by legacy_path)
            existing = self.engine.get_note_by_legacy_path(
                rel_posix, include_deleted=True, include_segments=True
            )
            now = self.engine.shim.now_iso()

            if existing is None:
                note = self.engine.create_note(
                    title,
                    rewritten_text,
                    notebook_id=notebook_id,
                    in_list=in_list,
                    list_pos=list_pos,
                    seed_segments=False,
                    legacy_path=rel_posix,
                    record_initial_revision=True,
                )
                note_id = note["id"]
            else:
                note_id = existing["id"]

            # Determine segments: if reading.db had segments for this path, migrate them
            # and refresh fingerprints against `lines` (so rewritten :/resource_id links
            # match the new body_sha without tripping external-drift needs_resync!)
            db_segs = legacy_segs.get(rel_posix)
            db_orphs = legacy_orphans.get(rel_posix, [])
            if db_segs:
                adapted_segs: list[dict[str, Any]] = []
                n_lines = len(lines)
                for s in db_segs:
                    sc = dict(s, cards_created=list(s.get("cards_created") or []))
                    st = max(1, min(int(sc["start_line"]), n_lines or 1))
                    en = max(st, min(int(sc["end_line"]), n_lines or st))
                    sc["start_line"] = st
                    sc["end_line"] = en
                    sc["fingerprint"] = seg_fingerprint(lines, st, en)
                    sc["first_line"] = lines[st - 1] if st - 1 < n_lines else ""
                    adapted_segs.append(sc)
            else:
                adapted_segs = seed_whole_note(
                    rewritten_text, title, start_id=1, now_iso=now
                )

            with self.engine.db.transaction():
                if added_at is not None or needs_resync:
                    self.engine.db.execute(
                        "UPDATE notes SET added_at = COALESCE(?, added_at), needs_resync = ? WHERE id = ?",
                        (added_at, 1 if needs_resync else 0, note_id),
                    )
                self.engine._save_note_segments(note_id, adapted_segs, db_orphs)

            path_to_note_id[rel_posix] = note_id
            notes_migrated += 1
            total_segments_migrated += len(adapted_segs)
            total_cards_migrated += sum(
                len(s.get("cards_created") or []) for s in adapted_segs
            )

        # 2. Migrate any historical/deleted rfiles not present on disk as soft-deleted notes
        # so historical Anki card provenance (`rcards`) is 100% preserved!
        migrated_paths = set(path_to_note_id.keys())
        for r_path, rf in sorted(rfiles.items()):
            if r_path in migrated_paths:
                continue
            db_segs = legacy_segs.get(r_path, [])
            db_orphs = legacy_orphans.get(r_path, [])
            if not db_segs and not db_orphs:
                continue

            rel_parent = Path(r_path).parent.as_posix()
            notebook_id = (
                self.engine.resolve_or_create_notebook_path(rel_parent)
                if rel_parent != "."
                else None
            )
            title = Path(r_path).stem or r_path
            existing = self.engine.get_note_by_legacy_path(
                r_path, include_deleted=True
            )
            now = self.engine.shim.now_iso()
            if existing is None:
                note = self.engine.create_note(
                    title,
                    "",
                    notebook_id=notebook_id,
                    in_list=False,
                    list_pos=int(rf.get("pos") or 0),
                    seed_segments=False,
                    legacy_path=r_path,
                    record_initial_revision=False,
                )
                note_id = note["id"]
            else:
                note_id = existing["id"]

            with self.engine.db.transaction():
                self.engine._save_note_segments(note_id, db_segs, db_orphs)
                self.engine.db.execute(
                    "UPDATE notes SET deleted_at = COALESCE(deleted_at, ?), in_list = 0 WHERE id = ?",
                    (now, note_id),
                )

            path_to_note_id[r_path] = note_id
            archived_missing_migrated += 1
            total_segments_migrated += len(db_segs)
            total_cards_migrated += sum(
                len(s.get("cards_created") or []) for s in db_segs
            )

        # 3. Optionally import any unreferenced images in _assets
        if import_unreferenced_assets:
            for img_path in self._images_by_rel.values():
                self._ensure_resource_imported(img_path)

        # 4. Migrate active reading round if present (adding `note_id` alongside `path`)
        rround = legacy_db["rround"]
        if isinstance(rround, dict):
            round_copy = dict(rround)
            if isinstance(round_copy.get("pending"), list):
                new_pending = []
                for item in round_copy["pending"]:
                    if isinstance(item, dict):
                        ic = dict(item)
                        p_str = ic.get("path", "")
                        if p_str in path_to_note_id:
                            ic["note_id"] = path_to_note_id[p_str]
                        new_pending.append(ic)
                    else:
                        new_pending.append(item)
                round_copy["pending"] = new_pending
            self.engine.set_reading_round(round_copy)

        self.engine.set_meta("legacy_migrated_at", self.engine.shim.now_iso())
        health = self.engine.check_health()

        return {
            "ok": health["ok"] and len(unresolved_links) == 0,
            "health": health,
            "corpus_md_files": len(md_files),
            "notes_migrated": notes_migrated,
            "archived_missing_notes_migrated": archived_missing_migrated,
            "notebooks_created": len(self.engine.list_notebooks(include_deleted=True)),
            "indexed_corpus_images": indexed_images,
            "resources_imported": len(self._resource_by_path),
            "unique_resources_stored": len(
                self.engine.db.query_all("SELECT id FROM resources")
            ),
            "markdown_image_links_rewritten": total_links_rewritten,
            "unresolved_image_links": unresolved_links,
            "segments_migrated": total_segments_migrated,
            "segment_cards_migrated": total_cards_migrated,
        }
