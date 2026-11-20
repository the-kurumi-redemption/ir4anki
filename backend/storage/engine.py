"""Joplin-mode StorageEngine / DAO for ir4anki.

Provides an atomic, UUID-driven, Single Source of Truth over `DatabaseDriver` and
`FsDriver`:
- Notebooks: hierarchical CRUD, cycle-safe move, soft delete & restore, tree assembly
- Notes: CRUD, move/rename in 1 SQL transaction, soft delete & restore, FTS5/LIKE search
- Revisions: automatic history snapshots on content/title changes, rollback to any revision
- Resources: flat media sandbox (`<resource_id>.<ext>`), SHA-256 deduplication, `(:/<id>)` tracking
- Progressive Reading Segments: whole-note seeding, bookmark split, in-app segment edit,
  external/full-note re-anchoring, reseed, Anki card provenance (`segment_cards`), round state
- Maintenance: `vacuum_into` hot backup, `integrity_check`, orphan resource GC
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
import mimetypes
from pathlib import Path
from typing import Any

from .domain import (
    apply_segment_edit,
    compute_bookmark_split,
    extract_resource_ids,
    infer_note_title,
    locate_quote_anchor,
    normalize_newlines,
    reanchor_annotations,
    reanchor_segments,
    reseed_segments,
    seed_whole_note,
)
from .drivers import DatabaseDriver, FsDriver, PlatformShim
from .schema import ensure_schema


class StorageConflictError(Exception):
    """Raised when an optimistic concurrency check (revision/fingerprint) or tree constraint fails."""


class StorageNotFoundError(LookupError):
    """Raised when a requested notebook, note, revision, resource, or segment does not exist."""


class StorageEngine:
    """Unified Data Access Object (DAO) decoupling business logic from host OS/DB."""

    def __init__(
        self,
        db: DatabaseDriver,
        fs: FsDriver,
        shim: PlatformShim | None = None,
    ) -> None:
        self.db = db
        self.fs = fs
        self.shim = shim or PlatformShim()
        self.schema_version = ensure_schema(self.db)

    def close(self) -> None:
        self.db.close()

    # ------------------------------------------------------------------
    # Metadata & Maintenance
    # ------------------------------------------------------------------

    def get_meta(self, key: str, default: str | None = None) -> str | None:
        row = self.db.query_one("SELECT value FROM storage_meta WHERE key = ?", (key,))
        return row["value"] if row is not None else default

    def set_meta(self, key: str, value: str) -> None:
        with self.db.transaction():
            self.db.execute(
                "INSERT INTO storage_meta(key, value) VALUES(?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, value),
            )

    def backup(self, target_dir: str | Path) -> dict[str, Any]:
        """Hot backup both SQLite `data.db` (via VACUUM INTO) and `media/` sandbox."""
        dest = Path(target_dir).resolve()
        dest.mkdir(parents=True, exist_ok=True)
        db_target = dest / "data.db"
        media_target = dest / "media"
        self.db.vacuum_into(db_target)
        self.fs.copy_all_to(media_target)
        return {
            "db_path": str(db_target),
            "media_dir": str(media_target),
            "media_files": len(self.fs.list_files()),
        }

    def check_health(self) -> dict[str, Any]:
        ok, issues = self.db.integrity_check()
        missing_blobs: list[str] = []
        for r in self.db.query_all(
            "SELECT id, ext FROM resources WHERE deleted_at IS NULL"
        ):
            blob_name = f"{r['id']}{r['ext']}"
            if not self.fs.exists(blob_name):
                missing_blobs.append(blob_name)
                issues.append(f"missing_resource_blob: {blob_name}")
        return {
            "ok": ok and not missing_blobs,
            "schema_version": self.schema_version,
            "issues": issues,
        }

    # ------------------------------------------------------------------
    # Notebooks (Folders) DAO
    # ------------------------------------------------------------------

    def create_notebook(
        self,
        name: str,
        *,
        parent_id: str | None = None,
        pos: int | None = None,
        notebook_id: str | None = None,
    ) -> dict[str, Any]:
        clean_name = (name or "").strip()
        if not clean_name or "/" in clean_name or "\\" in clean_name:
            raise ValueError(f"Invalid notebook name: {name!r}")

        now = self.shim.now_iso()
        nb_id = notebook_id or self.shim.new_id()

        with self.db.transaction():
            if parent_id is not None:
                parent = self.get_notebook(parent_id, include_deleted=False)
                if parent is None:
                    raise StorageNotFoundError(f"Parent notebook not found: {parent_id}")
            if pos is None:
                row = self.db.query_one(
                    "SELECT COALESCE(MAX(pos), -1) + 1 AS next_pos FROM notebooks "
                    "WHERE parent_id IS ? AND deleted_at IS NULL",
                    (parent_id,),
                )
                pos = int(row["next_pos"]) if row else 0

            self._assert_unique_notebook_name(parent_id, clean_name, exclude_id=nb_id)
            self.db.execute(
                "INSERT INTO notebooks(id, parent_id, name, pos, created_at, updated_at, deleted_at) "
                "VALUES(?, ?, ?, ?, ?, ?, NULL)",
                (nb_id, parent_id, clean_name, pos, now, now),
            )
        return self.get_notebook(nb_id, include_deleted=True)  # type: ignore[return-value]

    def _assert_unique_notebook_name(
        self, parent_id: str | None, name: str, *, exclude_id: str | None = None
    ) -> None:
        row = self.db.query_one(
            "SELECT id FROM notebooks "
            "WHERE parent_id IS ? AND name = ? AND deleted_at IS NULL AND id IS NOT ?",
            (parent_id, name, exclude_id),
        )
        if row is not None:
            raise StorageConflictError(f"同级目录下已存在同名笔记本：{name}")

    def get_notebook(
        self, notebook_id: str, *, include_deleted: bool = False
    ) -> dict[str, Any] | None:
        sql = "SELECT * FROM notebooks WHERE id = ?"
        if not include_deleted:
            sql += " AND deleted_at IS NULL"
        return self.db.query_one(sql, (notebook_id,))

    def list_notebooks(self, *, include_deleted: bool = False) -> list[dict[str, Any]]:
        sql = "SELECT * FROM notebooks"
        if not include_deleted:
            sql += " WHERE deleted_at IS NULL"
        sql += " ORDER BY parent_id NULLS FIRST, pos ASC, name ASC"
        return self.db.query_all(sql)

    def _refresh_subtree_paths(self, root_notebook_id: str | None = None) -> dict[str, str]:
        """Recompute canonical relative paths (`<notebook_trail>/<filename>.md`) for all notes
        under `root_notebook_id` (or all notes when None) and return `{old_path: new_path}` for changed paths."""
        if root_notebook_id is not None:
            nb_ids = self._descendant_notebook_ids(root_notebook_id)
            if not nb_ids:
                return {}
            placeholders = ",".join("?" for _ in nb_ids)
            notes = self.db.query_all(
                f"SELECT id, notebook_id, title, legacy_path FROM notes WHERE notebook_id IN ({placeholders})",
                nb_ids,
            )
        else:
            notes = self.db.query_all("SELECT id, notebook_id, title, legacy_path FROM notes")

        nb_path_cache: dict[str | None, str] = {None: ""}
        mapping: dict[str, str] = {}
        for n in notes:
            nb_id = n["notebook_id"]
            if nb_id not in nb_path_cache:
                trail = self.get_notebook_path(nb_id)
                nb_path_cache[nb_id] = "/".join(x["name"] for x in trail)
            dir_prefix = nb_path_cache[nb_id]
            old_lp = n["legacy_path"] or ""
            # Determine filename stem from existing legacy_path basename if present, else title
            old_base = Path(old_lp).name if old_lp else ""
            if not old_base or not old_base.lower().endswith(".md"):
                stem = (n["title"] or "未命名笔记").replace("/", "_")
                old_base = stem if stem.lower().endswith(".md") else f"{stem}.md"
            new_lp = f"{dir_prefix}/{old_base}" if dir_prefix else old_base
            if new_lp != old_lp:
                self.db.execute(
                    "UPDATE notes SET legacy_path = ? WHERE id = ?",
                    (new_lp, n["id"]),
                )
                if old_lp:
                    mapping[old_lp] = new_lp
        if mapping:
            self._remap_round_paths(mapping)
        return mapping

    def _remap_round_paths(self, mapping: dict[str, str]) -> None:
        rd = self.get_reading_round()
        if not isinstance(rd, dict):
            return
        touched = False
        for item in rd.get("pending") or []:
            p = item.get("path")
            if p in mapping:
                item["path"] = mapping[p]
                touched = True
        if touched:
            self.set_reading_round(rd)

    def rename_notebook(self, notebook_id: str, new_name: str) -> dict[str, Any]:
        clean_name = (new_name or "").strip()
        if not clean_name or "/" in clean_name or "\\" in clean_name:
            raise ValueError(f"Invalid notebook name: {new_name!r}")

        with self.db.transaction():
            nb = self.get_notebook(notebook_id, include_deleted=False)
            if nb is None:
                raise StorageNotFoundError(f"Notebook not found: {notebook_id}")
            self._assert_unique_notebook_name(
                nb["parent_id"], clean_name, exclude_id=notebook_id
            )
            now = self.shim.now_iso()
            self.db.execute(
                "UPDATE notebooks SET name = ?, updated_at = ? WHERE id = ?",
                (clean_name, now, notebook_id),
            )
            self._refresh_subtree_paths(notebook_id)
        return self.get_notebook(notebook_id)  # type: ignore[return-value]

    def move_notebook(
        self,
        notebook_id: str,
        new_parent_id: str | None,
        *,
        new_pos: int | None = None,
    ) -> dict[str, Any]:
        if notebook_id == new_parent_id:
            raise StorageConflictError("Cannot move a notebook into itself")

        with self.db.transaction():
            nb = self.get_notebook(notebook_id, include_deleted=False)
            if nb is None:
                raise StorageNotFoundError(f"Notebook not found: {notebook_id}")
            if new_parent_id is not None:
                parent = self.get_notebook(new_parent_id, include_deleted=False)
                if parent is None:
                    raise StorageNotFoundError(f"Target parent notebook not found: {new_parent_id}")
                # Cycle detection: walk up from new_parent_id to root
                cur_id: str | None = new_parent_id
                seen: set[str] = set()
                while cur_id is not None:
                    if cur_id == notebook_id:
                        raise StorageConflictError("Cannot move a notebook into its own descendant")
                    if cur_id in seen:
                        break
                    seen.add(cur_id)
                    p_row = self.db.query_one(
                        "SELECT parent_id FROM notebooks WHERE id = ?", (cur_id,)
                    )
                    cur_id = p_row["parent_id"] if p_row else None

            self._assert_unique_notebook_name(
                new_parent_id, nb["name"], exclude_id=notebook_id
            )
            if new_pos is None:
                row = self.db.query_one(
                    "SELECT COALESCE(MAX(pos), -1) + 1 AS next_pos FROM notebooks "
                    "WHERE parent_id IS ? AND deleted_at IS NULL",
                    (new_parent_id,),
                )
                new_pos = int(row["next_pos"]) if row else 0

            now = self.shim.now_iso()
            self.db.execute(
                "UPDATE notebooks SET parent_id = ?, pos = ?, updated_at = ? WHERE id = ?",
                (new_parent_id, new_pos, now, notebook_id),
            )
            self._refresh_subtree_paths(notebook_id)
        return self.get_notebook(notebook_id)  # type: ignore[return-value]

    def _descendant_notebook_ids(self, root_id: str) -> list[str]:
        rows = self.db.query_all(
            """
            WITH RECURSIVE sub(id) AS (
                SELECT id FROM notebooks WHERE id = ?
                UNION ALL
                SELECT n.id FROM notebooks n JOIN sub s ON n.parent_id = s.id
            )
            SELECT id FROM sub
            """,
            (root_id,),
        )
        return [r["id"] for r in rows]

    def soft_delete_notebook(self, notebook_id: str) -> dict[str, Any]:
        """Soft-delete a notebook, all its descendant notebooks, and all notes inside them."""
        with self.db.transaction():
            nb = self.get_notebook(notebook_id, include_deleted=False)
            if nb is None:
                raise StorageNotFoundError(f"Notebook not found: {notebook_id}")
            ids = self._descendant_notebook_ids(notebook_id)
            now = self.shim.now_iso()
            placeholders = ",".join("?" for _ in ids)
            self.db.execute(
                f"UPDATE notebooks SET deleted_at = ?, updated_at = ? "
                f"WHERE id IN ({placeholders}) AND deleted_at IS NULL",
                [now, now, *ids],
            )
            notes_deleted = self.db.execute(
                f"UPDATE notes SET deleted_at = ?, updated_at = ? "
                f"WHERE notebook_id IN ({placeholders}) AND deleted_at IS NULL",
                [now, now, *ids],
            )
        return {
            "notebook_id": notebook_id,
            "notebooks_deleted": len(ids),
            "notes_deleted": notes_deleted,
            "deleted_at": now,
        }

    def restore_notebook(self, notebook_id: str) -> dict[str, Any]:
        """Restore a soft-deleted notebook, its ancestor chain if deleted, its subtree, and notes."""
        with self.db.transaction():
            nb = self.get_notebook(notebook_id, include_deleted=True)
            if nb is None:
                raise StorageNotFoundError(f"Notebook not found: {notebook_id}")
            now = self.shim.now_iso()
            # Ensure ancestors are restored so the restored notebook is not orphaned in trash
            cur_parent = nb["parent_id"]
            while cur_parent is not None:
                p_row = self.get_notebook(cur_parent, include_deleted=True)
                if p_row is None:
                    break
                if p_row["deleted_at"] is not None:
                    self.db.execute(
                        "UPDATE notebooks SET deleted_at = NULL, updated_at = ? WHERE id = ?",
                        (now, cur_parent),
                    )
                cur_parent = p_row["parent_id"]

            ids = self._descendant_notebook_ids(notebook_id)
            placeholders = ",".join("?" for _ in ids)
            self.db.execute(
                f"UPDATE notebooks SET deleted_at = NULL, updated_at = ? WHERE id IN ({placeholders})",
                [now, *ids],
            )
            notes_restored = self.db.execute(
                f"UPDATE notes SET deleted_at = NULL, updated_at = ? WHERE notebook_id IN ({placeholders})",
                [now, *ids],
            )
        return {
            "notebook_id": notebook_id,
            "notebooks_restored": len(ids),
            "notes_restored": notes_restored,
        }

    def purge_notebook(self, notebook_id: str) -> None:
        """Permanently delete a notebook and cascade-delete all descendant notebooks and notes."""
        with self.db.transaction():
            nb = self.get_notebook(notebook_id, include_deleted=True)
            if nb is None:
                raise StorageNotFoundError(f"Notebook not found: {notebook_id}")
            ids = self._descendant_notebook_ids(notebook_id)
            placeholders = ",".join("?" for _ in ids)
            self.db.execute(
                f"DELETE FROM notes WHERE notebook_id IN ({placeholders})",
                ids,
            )
            self.db.execute("DELETE FROM notebooks WHERE id = ?", (notebook_id,))

    def get_notebook_path(self, notebook_id: str | None) -> list[dict[str, str]]:
        """Return breadcrumb list `[{"id": ..., "name": ...}, ...]` from root down to `notebook_id`."""
        if not notebook_id:
            return []
        trail: list[dict[str, str]] = []
        cur_id: str | None = notebook_id
        seen: set[str] = set()
        while cur_id and cur_id not in seen:
            seen.add(cur_id)
            row = self.db.query_one(
                "SELECT id, parent_id, name FROM notebooks WHERE id = ?", (cur_id,)
            )
            if row is None:
                break
            trail.append({"id": row["id"], "name": row["name"]})
            cur_id = row["parent_id"]
        trail.reverse()
        return trail

    def get_notebook_rel_path(self, notebook_id: str | None) -> str:
        """Return slash-separated relative path for `notebook_id` (or '' for root)."""
        trail = self.get_notebook_path(notebook_id)
        return "/".join(x["name"] for x in trail)

    def resolve_notebook(
        self, id_or_path: str | None, *, include_deleted: bool = False
    ) -> dict[str, Any] | None:
        """Resolve a notebook by UUID or by slash-separated path (e.g. '2026/解剖')."""
        if not id_or_path:
            return None
        by_id = self.get_notebook(id_or_path, include_deleted=include_deleted)
        if by_id is not None:
            return by_id
        parts = [p.strip() for p in id_or_path.replace("\\", "/").split("/") if p.strip() and p.strip() != "."]
        if not parts:
            return None
        parent_id: str | None = None
        cur_nb: dict[str, Any] | None = None
        for part in parts:
            sql = "SELECT * FROM notebooks WHERE parent_id IS ? AND name = ?"
            if not include_deleted:
                sql += " AND deleted_at IS NULL"
            cur_nb = self.db.query_one(sql, (parent_id, part))
            if cur_nb is None:
                return None
            parent_id = cur_nb["id"]
        return cur_nb

    def list_notebook_paths(self, *, include_deleted: bool = False) -> list[dict[str, Any]]:
        """Return all notebooks with their computed `path` field sorted by path."""
        nbs = self.list_notebooks(include_deleted=include_deleted)
        by_id = {n["id"]: n for n in nbs}
        out: list[dict[str, Any]] = []
        for n in nbs:
            parts: list[str] = []
            cur: dict[str, Any] | None = n
            seen: set[str] = set()
            while cur and cur["id"] not in seen:
                seen.add(cur["id"])
                parts.append(cur["name"])
                pid = cur.get("parent_id")
                cur = by_id.get(pid) if pid else None
            parts.reverse()
            out.append({**n, "path": "/".join(parts)})
        out.sort(key=lambda x: x["path"])
        return out

    def resolve_or_create_notebook_path(self, rel_dir: str) -> str | None:
        """Resolve a slash-separated directory path (e.g. '2026/金钱心理学') into notebook UUIDs,
        creating missing notebooks along the way. Returns leaf notebook_id (or None for root)."""
        parts = [p.strip() for p in (rel_dir or "").replace("\\", "/").split("/") if p.strip() and p.strip() != "."]
        if not parts:
            return None
        parent_id: str | None = None
        with self.db.transaction():
            for part in parts:
                row = self.db.query_one(
                    "SELECT id FROM notebooks WHERE parent_id IS ? AND name = ? AND deleted_at IS NULL",
                    (parent_id, part),
                )
                if row is not None:
                    parent_id = row["id"]
                else:
                    created = self.create_notebook(part, parent_id=parent_id)
                    parent_id = created["id"]
        return parent_id

    # ------------------------------------------------------------------
    # Notes, Revisions & Full-Text Search DAO
    # ------------------------------------------------------------------

    def _compute_note_legacy_path(self, notebook_id: str | None, title_or_filename: str) -> str:
        clean = (title_or_filename or "未命名笔记").strip().replace("/", "_")
        filename = clean if clean.lower().endswith(".md") else f"{clean}.md"
        dir_prefix = self.get_notebook_rel_path(notebook_id)
        return f"{dir_prefix}/{filename}" if dir_prefix else filename

    def create_note(
        self,
        title: str,
        body: str,
        *,
        notebook_id: str | None = None,
        note_id: str | None = None,
        in_list: bool = False,
        list_pos: int | None = None,
        seed_segments: bool = True,
        legacy_path: str | None = None,
        record_initial_revision: bool = True,
    ) -> dict[str, Any]:
        norm_body = normalize_newlines(body)
        lines = norm_body.split("\n")
        clean_title = (title or "").strip() or infer_note_title(lines, legacy_path or "未命名笔记")
        body_sha = self.shim.sha256_hex(norm_body)
        now = self.shim.now_iso()
        nid = note_id or self.shim.new_id()

        with self.db.transaction():
            if notebook_id is not None:
                nb = self.get_notebook(notebook_id, include_deleted=False)
                if nb is None:
                    raise StorageNotFoundError(f"Notebook not found: {notebook_id}")

            effective_path = legacy_path or self._compute_note_legacy_path(notebook_id, clean_title)

            if list_pos is None:
                if in_list:
                    row = self.db.query_one(
                        "SELECT COALESCE(MAX(list_pos), -1) + 1 AS next_pos FROM notes "
                        "WHERE in_list = 1 AND deleted_at IS NULL"
                    )
                    list_pos = int(row["next_pos"]) if row else 0
                else:
                    list_pos = 0

            added_at = now if in_list else None
            self.db.execute(
                """
                INSERT INTO notes(
                    id, notebook_id, title, body, body_sha,
                    in_list, list_pos, added_at, needs_resync, legacy_path,
                    created_at, updated_at, deleted_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, NULL)
                """,
                (
                    nid,
                    notebook_id,
                    clean_title,
                    norm_body,
                    body_sha,
                    1 if in_list else 0,
                    list_pos,
                    added_at,
                    effective_path,
                    now,
                    now,
                ),
            )

            if record_initial_revision:
                self._insert_revision(nid, clean_title, norm_body, body_sha, reason="create", now_iso=now)

            self._sync_note_resource_links(nid, norm_body)

            if seed_segments:
                segs = seed_whole_note(norm_body, clean_title, start_id=1, now_iso=now)
                self._save_note_segments(nid, segs, [])

        return self.get_note(nid, include_segments=True)  # type: ignore[return-value]

    def _insert_revision(
        self,
        note_id: str,
        title: str,
        body: str,
        body_sha: str,
        *,
        reason: str = "edit",
        now_iso: str | None = None,
    ) -> int:
        ts = now_iso or self.shim.now_iso()
        self.db.execute(
            "INSERT INTO note_revisions(note_id, title, body, body_sha, reason, created_at) "
            "VALUES(?, ?, ?, ?, ?, ?)",
            (note_id, title, body, body_sha, reason, ts),
        )
        row = self.db.query_one("SELECT last_insert_rowid() AS id")
        return int(row["id"]) if row else 0

    def _sync_note_resource_links(self, note_id: str, body: str) -> None:
        res_ids = extract_resource_ids(body)
        self.db.execute("DELETE FROM note_resources WHERE note_id = ?", (note_id,))
        if not res_ids:
            return
        placeholders = ",".join("?" for _ in res_ids)
        existing = self.db.query_all(
            f"SELECT id FROM resources WHERE id IN ({placeholders})", res_ids
        )
        valid_ids = [r["id"] for r in existing]
        if valid_ids:
            self.db.executemany(
                "INSERT OR IGNORE INTO note_resources(note_id, resource_id) VALUES(?, ?)",
                [(note_id, rid) for rid in valid_ids],
            )

    def get_note(
        self,
        note_id: str,
        *,
        include_deleted: bool = False,
        include_segments: bool = False,
    ) -> dict[str, Any] | None:
        sql = "SELECT * FROM notes WHERE id = ?"
        if not include_deleted:
            sql += " AND deleted_at IS NULL"
        row = self.db.query_one(sql, (note_id,))
        if row is None:
            return None
        note = dict(row)
        note["in_list"] = bool(note["in_list"])
        note["needs_resync"] = bool(note["needs_resync"])
        note["notebook_path"] = self.get_notebook_path(note["notebook_id"])
        note["path"] = note.get("legacy_path") or self._compute_note_legacy_path(note["notebook_id"], note["title"])
        if include_segments:
            note["segments"] = self.get_note_segments(note_id)
            note["orphans"] = self.get_note_orphans(note_id)
        return note

    def get_note_by_legacy_path(
        self, legacy_path: str, *, include_deleted: bool = False, include_segments: bool = False
    ) -> dict[str, Any] | None:
        norm_path = (legacy_path or "").strip().replace("\\", "/").lstrip("/")
        sql = "SELECT id FROM notes WHERE legacy_path = ?"
        if not include_deleted:
            sql += " AND deleted_at IS NULL"
        row = self.db.query_one(sql, (norm_path,))
        if row is None and include_deleted:
            # Prefer active note if both active and deleted exist with same legacy_path
            row = self.db.query_one(
                "SELECT id FROM notes WHERE legacy_path = ? ORDER BY CASE WHEN deleted_at IS NULL THEN 0 ELSE 1 END, updated_at DESC LIMIT 1",
                (norm_path,),
            )
        if row is None:
            return None
        return self.get_note(
            row["id"], include_deleted=include_deleted, include_segments=include_segments
        )

    def resolve_note(
        self,
        id_or_path: str,
        *,
        include_deleted: bool = False,
        include_segments: bool = False,
    ) -> dict[str, Any] | None:
        """Resolve a note by either its 32-char UUID (`id`) or its relative path (`legacy_path`)."""
        if not id_or_path:
            return None
        by_id = self.get_note(
            id_or_path, include_deleted=include_deleted, include_segments=include_segments
        )
        if by_id is not None:
            return by_id
        return self.get_note_by_legacy_path(
            id_or_path, include_deleted=include_deleted, include_segments=include_segments
        )

    def list_notes(
        self,
        *,
        notebook_id: str | None = None,
        filter_by_notebook: bool = False,
        in_list_only: bool = False,
        include_deleted: bool = False,
    ) -> list[dict[str, Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if not include_deleted:
            clauses.append("deleted_at IS NULL")
        if filter_by_notebook:
            clauses.append("notebook_id IS ?")
            params.append(notebook_id)
        if in_list_only:
            clauses.append("in_list = 1")
        where_sql = (" WHERE " + " AND ".join(clauses)) if clauses else ""
        order_sql = (
            " ORDER BY list_pos ASC, created_at ASC"
            if in_list_only
            else " ORDER BY legacy_path COLLATE NOCASE ASC, title COLLATE NOCASE ASC, created_at ASC"
        )
        rows = self.db.query_all(f"SELECT * FROM notes{where_sql}{order_sql}", params)
        for r in rows:
            r["in_list"] = bool(r["in_list"])
            r["needs_resync"] = bool(r["needs_resync"])
            r["path"] = r.get("legacy_path") or r["title"]
        return rows

    def rename_note(self, note_id: str, new_name_or_title: str) -> dict[str, Any]:
        """Rename a note (updates `title` and `legacy_path` in 1 transaction without touching body/sha)."""
        clean = (new_name_or_title or "").strip()
        if not clean or "/" in clean or "\\" in clean:
            raise ValueError(f"Invalid note name: {new_name_or_title!r}")
        filename = clean if clean.lower().endswith(".md") else f"{clean}.md"
        new_title = Path(filename).stem

        with self.db.transaction():
            note = self.get_note(note_id, include_deleted=False)
            if note is None:
                raise StorageNotFoundError(f"Note not found: {note_id}")
            new_lp = self._compute_note_legacy_path(note["notebook_id"], filename)
            conflict = self.db.query_one(
                "SELECT id FROM notes WHERE legacy_path = ? AND deleted_at IS NULL AND id != ?",
                (new_lp, note_id),
            )
            if conflict is not None:
                raise StorageConflictError(f"目标名称已存在：{new_lp}")
            old_lp = note.get("legacy_path") or ""
            now = self.shim.now_iso()
            self.db.execute(
                "UPDATE notes SET title = ?, legacy_path = ?, updated_at = ? WHERE id = ?",
                (new_title, new_lp, now, note_id),
            )
            if old_lp and old_lp != new_lp:
                self._remap_round_paths({old_lp: new_lp})
        return self.get_note(note_id)  # type: ignore[return-value]

    def update_note(
        self,
        note_id: str,
        *,
        title: str | None = None,
        body: str | None = None,
        expected_body_sha: str | None = None,
        reason: str = "edit",
    ) -> dict[str, Any]:
        """Update a note's title and/or markdown body, creating a revision snapshot
        and automatically re-anchoring progressive reading segments if body changed."""
        with self.db.transaction():
            note = self.get_note(note_id, include_deleted=False, include_segments=True)
            if note is None:
                raise StorageNotFoundError(f"Note not found: {note_id}")
            if expected_body_sha is not None and note["body_sha"] != expected_body_sha:
                raise StorageConflictError(
                    "内容已被其他操作修改；请刷新后合并"
                )

            new_title = (title.strip() if title is not None else note["title"]) or note["title"]
            new_body = normalize_newlines(body) if body is not None else note["body"]
            new_sha = self.shim.sha256_hex(new_body)
            now = self.shim.now_iso()

            changed_content = new_sha != note["body_sha"] or new_title != note["title"]
            needs_resync = bool(note["needs_resync"])

            new_lp = note.get("legacy_path")
            if title is not None and new_title != note["title"]:
                new_lp = self._compute_note_legacy_path(note["notebook_id"], new_title)

            if new_sha != note["body_sha"]:
                lines = new_body.split("\n")
                segs = note.get("segments") or []
                orphans = note.get("orphans") or []
                if segs:
                    kept_segs, out_orphans, damaged = reanchor_segments(segs, orphans, lines)
                    self._save_note_segments(note_id, kept_segs, out_orphans)
                    if damaged:
                        needs_resync = True
                elif note["in_list"]:
                    seeded = seed_whole_note(new_body, new_title, start_id=1, now_iso=now)
                    self._save_note_segments(note_id, seeded, orphans)

                self._sync_note_resource_links(note_id, new_body)
                self._reanchor_note_annotations(note_id, new_body, now_iso=now)

            if changed_content:
                self._insert_revision(
                    note_id, new_title, new_body, new_sha, reason=reason, now_iso=now
                )

            self.db.execute(
                """
                UPDATE notes
                SET title = ?, body = ?, body_sha = ?, needs_resync = ?, legacy_path = ?, updated_at = ?
                WHERE id = ?
                """,
                (new_title, new_body, new_sha, 1 if needs_resync else 0, new_lp, now, note_id),
            )
            old_lp = note.get("legacy_path") or ""
            if old_lp and new_lp and old_lp != new_lp:
                self._remap_round_paths({old_lp: new_lp})
        return self.get_note(note_id, include_segments=True)  # type: ignore[return-value]

    def update_note_body(
        self,
        note_id: str,
        body: str,
        *,
        reason: str = "edit",
        reanchor: bool = True,
    ) -> dict[str, Any]:
        """Update a note's markdown body and record a revision + resource links."""
        if reanchor:
            return self.update_note(note_id, body=body, reason=reason)
        with self.db.transaction():
            note = self.get_note(note_id, include_deleted=False)
            if note is None:
                raise StorageNotFoundError(f"Note not found: {note_id}")
            new_body = normalize_newlines(body)
            new_sha = self.shim.sha256_hex(new_body)
            now = self.shim.now_iso()
            if new_sha != note["body_sha"]:
                self._insert_revision(
                    note_id, note["title"], new_body, new_sha, reason=reason, now_iso=now
                )
                self._sync_note_resource_links(note_id, new_body)
                self._reanchor_note_annotations(note_id, new_body, now_iso=now)
                self.db.execute(
                    "UPDATE notes SET body = ?, body_sha = ?, updated_at = ? WHERE id = ?",
                    (new_body, new_sha, now, note_id),
                )
        return self.get_note(note_id, include_segments=True)  # type: ignore[return-value]

    def move_note(self, note_id: str, target_notebook_id: str | None) -> dict[str, Any]:
        """Atomically move a note to another notebook (or root when None). Single SQL UPDATE!"""
        with self.db.transaction():
            note = self.get_note(note_id, include_deleted=False)
            if note is None:
                raise StorageNotFoundError(f"Note not found: {note_id}")
            if target_notebook_id is not None:
                nb = self.get_notebook(target_notebook_id, include_deleted=False)
                if nb is None:
                    raise StorageNotFoundError(f"Target notebook not found: {target_notebook_id}")
            old_lp = note.get("legacy_path") or ""
            old_base = Path(old_lp).name if old_lp else f"{note['title']}.md"
            new_lp = self._compute_note_legacy_path(target_notebook_id, old_base)
            conflict = self.db.query_one(
                "SELECT id FROM notes WHERE legacy_path = ? AND deleted_at IS NULL AND id != ?",
                (new_lp, note_id),
            )
            if conflict is not None:
                raise StorageConflictError(f"目标位置已有同名笔记：{new_lp}")
            now = self.shim.now_iso()
            self.db.execute(
                "UPDATE notes SET notebook_id = ?, legacy_path = ?, updated_at = ? WHERE id = ?",
                (target_notebook_id, new_lp, now, note_id),
            )
            if old_lp and old_lp != new_lp:
                self._remap_round_paths({old_lp: new_lp})
        return self.get_note(note_id)  # type: ignore[return-value]

    def soft_delete_note(self, note_id: str) -> dict[str, Any]:
        with self.db.transaction():
            note = self.get_note(note_id, include_deleted=False)
            if note is None:
                raise StorageNotFoundError(f"Note not found: {note_id}")
            now = self.shim.now_iso()
            self.db.execute(
                "UPDATE notes SET deleted_at = ?, updated_at = ? WHERE id = ?",
                (now, now, note_id),
            )
        return self.get_note(note_id, include_deleted=True)  # type: ignore[return-value]

    def restore_note(self, note_id: str) -> dict[str, Any]:
        with self.db.transaction():
            note = self.get_note(note_id, include_deleted=True)
            if note is None:
                raise StorageNotFoundError(f"Note not found: {note_id}")
            now = self.shim.now_iso()
            # If the note's parent notebook is soft-deleted, restore its ancestor chain too
            nb_id = note.get("notebook_id")
            if nb_id:
                nb = self.get_notebook(nb_id, include_deleted=True)
                if nb and nb.get("deleted_at") is not None:
                    self.restore_notebook(nb_id)
            self.db.execute(
                "UPDATE notes SET deleted_at = NULL, updated_at = ? WHERE id = ?",
                (now, note_id),
            )
        return self.get_note(note_id, include_deleted=False)  # type: ignore[return-value]

    def purge_note(self, note_id: str) -> None:
        with self.db.transaction():
            note = self.get_note(note_id, include_deleted=True)
            if note is None:
                raise StorageNotFoundError(f"Note not found: {note_id}")
            self.db.execute("DELETE FROM notes WHERE id = ?", (note_id,))

    def list_trash(self) -> dict[str, list[dict[str, Any]]]:
        """Return all soft-deleted notebooks and notes currently in the recycle bin."""
        notebooks = self.db.query_all(
            "SELECT * FROM notebooks WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC"
        )
        notes = self.db.query_all(
            "SELECT id, notebook_id, title, body_sha, in_list, list_pos, legacy_path, "
            "created_at, updated_at, deleted_at FROM notes "
            "WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC"
        )
        return {"notebooks": notebooks, "notes": notes}

    def empty_trash(self) -> dict[str, int]:
        """Permanently purge all soft-deleted notes and notebooks."""
        with self.db.transaction():
            notes_purged = self.db.execute("DELETE FROM notes WHERE deleted_at IS NOT NULL")
            nbs_purged = self.db.execute("DELETE FROM notebooks WHERE deleted_at IS NOT NULL")
        return {"notes_purged": notes_purged, "notebooks_purged": nbs_purged}

    def list_note_revisions(self, note_id: str) -> list[dict[str, Any]]:
        note = self.get_note(note_id, include_deleted=True)
        if note is None:
            raise StorageNotFoundError(f"Note not found: {note_id}")
        return self.db.query_all(
            "SELECT id, note_id, title, body_sha, reason, created_at, length(body) AS byte_length "
            "FROM note_revisions WHERE note_id = ? ORDER BY id DESC",
            (note_id,),
        )

    list_revisions = list_note_revisions

    def get_note_revision(self, revision_id: int) -> dict[str, Any] | None:
        return self.db.query_one(
            "SELECT * FROM note_revisions WHERE id = ?", (revision_id,)
        )

    get_revision = get_note_revision

    def restore_note_revision(self, note_id: str, revision_id: int) -> dict[str, Any]:
        """Roll back a note to a historical revision snapshot (creates a new 'restore' revision)."""
        rev = self.get_note_revision(revision_id)
        if rev is None or rev["note_id"] != note_id:
            raise StorageNotFoundError(f"Revision {revision_id} not found for note {note_id}")
        return self.update_note(
            note_id,
            title=rev["title"],
            body=rev["body"],
            reason=f"restore:{revision_id}",
        )

    restore_revision = restore_note_revision

    def search_notes(
        self,
        query: str,
        *,
        notebook_id: str | None = None,
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        """Full-text search across active notes (title + body).

        Uses FTS5 trigram index for queries >= 3 chars when enabled, with automatic
        fallback to exact substring LIKE for 1-2 char CJK/ASCII queries.
        """
        q = (query or "").strip()
        if not q:
            return []

        nb_filter_sql = " AND n.notebook_id = ?" if notebook_id is not None else ""
        nb_params: tuple[Any, ...] = (notebook_id,) if notebook_id is not None else ()

        fts_enabled = self.get_meta("fts_enabled") == "1"
        if fts_enabled and len(q) >= 3:
            escaped_q = '"' + q.replace('"', '""') + '"'
            try:
                rows = self.db.query_all(
                    f"""
                    SELECT n.id, n.notebook_id, n.title, n.body_sha, n.in_list, n.list_pos,
                           n.needs_resync, n.legacy_path, n.created_at, n.updated_at,
                           snippet(notes_fts, 2, '[', ']', '…', 24) AS snippet
                    FROM notes_fts
                    JOIN notes n ON n.rowid = notes_fts.rowid
                    WHERE notes_fts MATCH ? AND n.deleted_at IS NULL{nb_filter_sql}
                    ORDER BY rank
                    LIMIT ?
                    """,
                    (escaped_q, *nb_params, limit),
                )
                for r in rows:
                    r["in_list"] = bool(r["in_list"])
                    r["needs_resync"] = bool(r["needs_resync"])
                return rows
            except Exception:
                pass

        like_pat = f"%{q}%"
        like_nb_sql = " AND notebook_id = ?" if notebook_id is not None else ""
        rows = self.db.query_all(
            f"""
            SELECT id, notebook_id, title, body, body_sha, in_list, list_pos,
                   needs_resync, legacy_path, created_at, updated_at
            FROM notes
            WHERE deleted_at IS NULL AND (title LIKE ? OR body LIKE ?){like_nb_sql}
            ORDER BY CASE WHEN title LIKE ? THEN 0 ELSE 1 END, updated_at DESC
            LIMIT ?
            """,
            (like_pat, like_pat, *nb_params, like_pat, limit),
        )
        out: list[dict[str, Any]] = []
        for r in rows:
            body_text = r.pop("body", "")
            idx = body_text.lower().find(q.lower())
            if idx >= 0:
                start = max(0, idx - 20)
                end = min(len(body_text), idx + len(q) + 28)
                snippet = ("…" if start > 0 else "") + body_text[start:end].replace("\n", " ") + ("…" if end < len(body_text) else "")
            else:
                snippet = body_text[:48].replace("\n", " ")
            r["in_list"] = bool(r["in_list"])
            r["needs_resync"] = bool(r["needs_resync"])
            r["snippet"] = snippet
            out.append(r)
        return out

    # ------------------------------------------------------------------
    # Resources (Media Sandbox) DAO
    # ------------------------------------------------------------------

    def put_resource(
        self,
        filename: str,
        data: bytes,
        *,
        mime_type: str | None = None,
        resource_id: str | None = None,
        deduplicate: bool = True,
        legacy_name: str | None = None,
    ) -> dict[str, Any]:
        """Store a media blob in the flat sandbox (`<resource_id>.<ext>`) and register in SQLite."""
        if not data:
            raise ValueError("Resource data cannot be empty")
        clean_filename = Path(filename or "resource.bin").name
        ext = Path(clean_filename).suffix.lower() or ".bin"
        if not mime_type:
            guessed, _ = mimetypes.guess_type(clean_filename)
            mime_type = guessed or "application/octet-stream"

        sha256 = self.shim.sha256_hex(data)
        if deduplicate and resource_id is None:
            existing = self.db.query_one(
                "SELECT * FROM resources WHERE sha256 = ? AND ext = ? AND deleted_at IS NULL LIMIT 1",
                (sha256, ext),
            )
            if existing is not None and self.fs.exists(f"{existing['id']}{existing['ext']}"):
                return dict(
                    existing,
                    blob_name=f"{existing['id']}{existing['ext']}",
                    markdown_ref=f":/{existing['id']}",
                    deduplicated=True,
                )

        rid = (resource_id or self.shim.new_id()).lower()
        blob_name = f"{rid}{ext}"
        now = self.shim.now_iso()

        # Write blob to sandbox first (atomic write), then record metadata in DB
        self.fs.write_bytes(blob_name, data)
        try:
            with self.db.transaction():
                self.db.execute(
                    """
                    INSERT INTO resources(id, filename, ext, mime_type, file_size, sha256, legacy_name, created_at, deleted_at)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(id) DO UPDATE SET
                        filename = excluded.filename,
                        ext = excluded.ext,
                        mime_type = excluded.mime_type,
                        file_size = excluded.file_size,
                        sha256 = excluded.sha256,
                        legacy_name = COALESCE(excluded.legacy_name, resources.legacy_name),
                        deleted_at = NULL
                    """,
                    (rid, clean_filename, ext, mime_type, len(data), sha256, legacy_name, now),
                )
        except BaseException:
            self.fs.delete(blob_name)
            raise

        created = self.get_resource(rid)
        assert created is not None
        created["deduplicated"] = False
        return created

    import_resource_bytes = put_resource

    def get_resource(
        self, resource_id: str, *, include_deleted: bool = False
    ) -> dict[str, Any] | None:
        rid = (resource_id or "").lower().strip()
        sql = "SELECT * FROM resources WHERE id = ?"
        if not include_deleted:
            sql += " AND deleted_at IS NULL"
        row = self.db.query_one(sql, (rid,))
        if row is None:
            return None
        res = dict(row)
        res["blob_name"] = f"{res['id']}{res['ext']}"
        res["markdown_ref"] = f":/{res['id']}"
        return res

    def get_resource_by_sha256(
        self, sha256: str, *, ext: str | None = None
    ) -> dict[str, Any] | None:
        clean_sha = (sha256 or "").lower().strip()
        if not clean_sha:
            return None
        if ext is not None:
            clean_ext = ext.lower() if ext.startswith(".") else f".{ext.lower()}"
            row = self.db.query_one(
                "SELECT id, ext FROM resources WHERE sha256 = ? AND ext = ? AND deleted_at IS NULL LIMIT 1",
                (clean_sha, clean_ext),
            )
        else:
            row = self.db.query_one(
                "SELECT id, ext FROM resources WHERE sha256 = ? AND deleted_at IS NULL LIMIT 1",
                (clean_sha,),
            )
        if row is None or not self.fs.exists(f"{row['id']}{row['ext']}"):
            return None
        return self.get_resource(row["id"])

    def get_resource_by_legacy_name(self, legacy_name: str) -> dict[str, Any] | None:
        row = self.db.query_one(
            "SELECT id FROM resources WHERE legacy_name = ? AND deleted_at IS NULL LIMIT 1",
            (legacy_name,),
        )
        return self.get_resource(row["id"]) if row else None

    def read_resource_bytes(self, resource_id: str) -> tuple[dict[str, Any], bytes]:
        res = self.get_resource(resource_id, include_deleted=False)
        if res is None:
            raise StorageNotFoundError(f"Resource not found: {resource_id}")
        try:
            data = self.fs.read_bytes(res["blob_name"])
        except FileNotFoundError as exc:
            raise StorageNotFoundError(f"Resource blob missing: {res['blob_name']}") from exc
        return res, data

    def find_unreferenced_resources(self, *, min_age_seconds: int = 0) -> list[dict[str, Any]]:
        """List resources not linked by any note (including soft-deleted notes in trash).

        When `min_age_seconds > 0`, resources created within the grace window are excluded
        so in-flight multi-step uploads are never collected prematurely.
        """
        rows = self.db.query_all(
            """
            SELECT r.* FROM resources r
            LEFT JOIN note_resources nr ON nr.resource_id = r.id
            WHERE nr.note_id IS NULL
            ORDER BY r.created_at ASC
            """
        )
        if min_age_seconds <= 0:
            return rows
        now_dt = datetime.fromisoformat(self.shim.now_iso().replace("Z", "+00:00"))
        if now_dt.tzinfo is None:
            now_dt = now_dt.replace(tzinfo=timezone.utc)
        cutoff = now_dt - timedelta(seconds=min_age_seconds)
        out: list[dict[str, Any]] = []
        for r in rows:
            raw_ts = (r.get("created_at") or "").strip()
            if not raw_ts:
                out.append(r)
                continue
            try:
                created_dt = datetime.fromisoformat(raw_ts.replace("Z", "+00:00"))
                if created_dt.tzinfo is None:
                    created_dt = created_dt.replace(tzinfo=timezone.utc)
                if created_dt <= cutoff:
                    out.append(r)
            except ValueError:
                out.append(r)
        return out

    def gc_unreferenced_resources(self, *, min_age_seconds: int = 0) -> int:
        """Delete unreferenced resource rows and their sandbox blobs."""
        unref = self.find_unreferenced_resources(min_age_seconds=min_age_seconds)
        deleted = 0
        for r in unref:
            blob_name = f"{r['id']}{r['ext']}"
            with self.db.transaction():
                self.db.execute("DELETE FROM resources WHERE id = ?", (r["id"],))
            self.fs.delete(blob_name)
            deleted += 1
        return deleted

    # ------------------------------------------------------------------
    # Progressive Reading List & Segments DAO
    # ------------------------------------------------------------------

    def get_note_segments(self, note_id: str) -> list[dict[str, Any]]:
        seg_rows = self.db.query_all(
            "SELECT * FROM segments WHERE note_id = ? ORDER BY start_line ASC, seg_id ASC",
            (note_id,),
        )
        card_rows = self.db.query_all(
            "SELECT seg_id, anki_note_id FROM segment_cards WHERE note_id = ? ORDER BY id ASC",
            (note_id,),
        )
        cards_by_seg: dict[int, list[int]] = {}
        for cr in card_rows:
            cards_by_seg.setdefault(int(cr["seg_id"]), []).append(int(cr["anki_note_id"]))

        out: list[dict[str, Any]] = []
        for r in seg_rows:
            try:
                hp = json.loads(r["heading_path"]) if r["heading_path"] else []
            except Exception:
                hp = []
            seg: dict[str, Any] = {
                "seg_id": int(r["seg_id"]),
                "start_line": int(r["start_line"]),
                "end_line": int(r["end_line"]),
                "fingerprint": r["fingerprint"] or "",
                "first_line": r["first_line"] or "",
                "title": r["title"] or "",
                "heading_path": hp,
                "status": r["status"] or "todo",
                "parent_seg_id": r["parent_seg_id"],
                "stale": bool(r["stale"]),
                "updated_at": r["updated_at"],
                "cards_created": cards_by_seg.get(int(r["seg_id"]), []),
            }
            out.append(seg)
        return out

    def get_note_orphans(self, note_id: str) -> list[dict[str, Any]]:
        rows = self.db.query_all(
            "SELECT chunk_key, data FROM note_orphans WHERE note_id = ? ORDER BY id ASC",
            (note_id,),
        )
        out: list[dict[str, Any]] = []
        for r in rows:
            try:
                payload = json.loads(r["data"]) if r["data"] else {}
            except Exception:
                payload = {}
            out.append({"chunk_key": r["chunk_key"], **payload})
        return out

    def _save_note_segments(
        self,
        note_id: str,
        segments: list[dict[str, Any]],
        orphans: list[dict[str, Any]] | None = None,
    ) -> None:
        """Persist `segments` + `segment_cards` + `note_orphans` for `note_id` inside a transaction."""
        old_segs = {
            int(r["seg_id"]): r
            for r in self.db.query_all("SELECT * FROM segments WHERE note_id = ?", (note_id,))
        }
        new_seg_ids = {int(s["seg_id"]) for s in (segments or [])}

        for sid in old_segs.keys() - new_seg_ids:
            self.db.execute(
                "DELETE FROM segments WHERE note_id = ? AND seg_id = ?", (note_id, sid)
            )

        for s in segments or []:
            sid = int(s["seg_id"])
            hp_json = json.dumps(s.get("heading_path") or [], ensure_ascii=False)
            stale_int = 1 if s.get("stale") else 0
            self.db.execute(
                """
                INSERT INTO segments(
                    note_id, seg_id, start_line, end_line, fingerprint, first_line,
                    title, heading_path, status, parent_seg_id, stale, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(note_id, seg_id) DO UPDATE SET
                    start_line = excluded.start_line,
                    end_line = excluded.end_line,
                    fingerprint = excluded.fingerprint,
                    first_line = excluded.first_line,
                    title = excluded.title,
                    heading_path = excluded.heading_path,
                    status = excluded.status,
                    parent_seg_id = excluded.parent_seg_id,
                    stale = excluded.stale,
                    updated_at = excluded.updated_at
                """,
                (
                    note_id,
                    sid,
                    int(s.get("start_line", 1)),
                    int(s.get("end_line", s.get("start_line", 1))),
                    s.get("fingerprint", ""),
                    s.get("first_line", ""),
                    s.get("title", ""),
                    hp_json,
                    s.get("status", "todo"),
                    s.get("parent_seg_id"),
                    stale_int,
                    s.get("updated_at"),
                ),
            )
            cards = [int(nid) for nid in (s.get("cards_created") or [])]
            self.db.execute(
                "DELETE FROM segment_cards WHERE note_id = ? AND seg_id = ?",
                (note_id, sid),
            )
            if cards:
                self.db.executemany(
                    "INSERT INTO segment_cards(note_id, seg_id, anki_note_id) VALUES(?, ?, ?)",
                    [(note_id, sid, nid) for nid in cards],
                )

        if orphans is not None:
            self.db.execute("DELETE FROM note_orphans WHERE note_id = ?", (note_id,))
            orphan_rows: list[tuple[str, str, str]] = []
            for o in orphans:
                copy_o = dict(o or {})
                ck = str(copy_o.pop("chunk_key", ""))
                orphan_rows.append((note_id, ck, json.dumps(copy_o, ensure_ascii=False)))
            if orphan_rows:
                self.db.executemany(
                    "INSERT INTO note_orphans(note_id, chunk_key, data) VALUES(?, ?, ?)",
                    orphan_rows,
                )

    def set_reading_list_membership(
        self, note_id: str, in_list: bool, *, pos: int | None = None
    ) -> dict[str, Any]:
        with self.db.transaction():
            note = self.get_note(note_id, include_deleted=False, include_segments=True)
            if note is None:
                raise StorageNotFoundError(f"Note not found: {note_id}")
            now = self.shim.now_iso()
            if in_list:
                if pos is None:
                    row = self.db.query_one(
                        "SELECT COALESCE(MAX(list_pos), -1) + 1 AS next_pos FROM notes "
                        "WHERE in_list = 1 AND deleted_at IS NULL AND id != ?",
                        (note_id,),
                    )
                    pos = int(row["next_pos"]) if row else 0
                added_at = note.get("added_at") or now
                if not note.get("segments"):
                    segs = seed_whole_note(note["body"], note["title"], start_id=1, now_iso=now)
                    self._save_note_segments(note_id, segs, note.get("orphans") or [])
                self.db.execute(
                    "UPDATE notes SET in_list = 1, list_pos = ?, added_at = ?, updated_at = ? WHERE id = ?",
                    (pos, added_at, now, note_id),
                )
            else:
                self.db.execute(
                    "UPDATE notes SET in_list = 0, updated_at = ? WHERE id = ?",
                    (now, note_id),
                )
        return self.get_note(note_id, include_segments=True)  # type: ignore[return-value]

    def reorder_reading_list(self, note_ids: list[str]) -> list[str]:
        """Set priority ordering of the reading list."""
        with self.db.transaction():
            listed = self.db.query_all(
                "SELECT id FROM notes WHERE in_list = 1 AND deleted_at IS NULL ORDER BY list_pos ASC"
            )
            current_ids = [r["id"] for r in listed]
            seen: set[str] = set()
            ordered: list[str] = []
            for nid in note_ids:
                if nid in current_ids and nid not in seen:
                    ordered.append(nid)
                    seen.add(nid)
            for nid in current_ids:
                if nid not in seen:
                    ordered.append(nid)
                    seen.add(nid)
            for pos, nid in enumerate(ordered):
                self.db.execute(
                    "UPDATE notes SET list_pos = ? WHERE id = ?", (pos, nid)
                )
        return ordered

    def split_segment(
        self,
        note_id: str,
        seg_id: int,
        selections: list[dict[str, int]],
        *,
        expected_fingerprint: str | None = None,
        expected_line_start: int | None = None,
    ) -> dict[str, Any]:
        """Bookmark-split a segment into container + children inside an atomic transaction."""
        with self.db.transaction():
            note = self.get_note(note_id, include_deleted=False, include_segments=True)
            if note is None:
                raise StorageNotFoundError(f"Note not found: {note_id}")
            if note["needs_resync"]:
                raise StorageConflictError("file needs reseed first")

            lines = note["body"].split("\n")
            now = self.shim.now_iso()
            try:
                res = compute_bookmark_split(
                    note["segments"],
                    note["orphans"],
                    lines,
                    seg_id,
                    selections,
                    expected_fingerprint=expected_fingerprint,
                    expected_line_start=expected_line_start,
                    now_iso=now,
                )
            except LookupError as exc:
                raise StorageNotFoundError(str(exc)) from exc
            except ValueError as exc:
                msg = str(exc)
                if msg.startswith("stale:") or msg == "segment already split":
                    raise StorageConflictError(msg) from exc
                raise

            self._save_note_segments(note_id, res["updated_segments"], note["orphans"])
        return res

    def edit_segment(
        self,
        note_id: str,
        seg_id: int,
        new_seg_text: str,
        *,
        expected_body_sha: str | None = None,
        expected_fingerprint: str | None = None,
    ) -> dict[str, Any]:
        """In-app edit of a single segment's text: atomically updates `notes.body`,
        records a `note_revisions` snapshot, shifts sibling/container coordinates,
        and updates `note_resources` in a single SQLite transaction!"""
        with self.db.transaction():
            note = self.get_note(note_id, include_deleted=False, include_segments=True)
            if note is None:
                raise StorageNotFoundError(f"Note not found: {note_id}")
            if note["needs_resync"]:
                raise StorageConflictError("file needs reseed first")
            if expected_body_sha is not None and note["body_sha"] != expected_body_sha:
                raise StorageConflictError("内容已被其他编辑器修改；请重新打开后合并")

            now = self.shim.now_iso()
            try:
                res = apply_segment_edit(
                    note["segments"],
                    note["orphans"],
                    note["body"],
                    seg_id,
                    new_seg_text,
                    expected_fingerprint=expected_fingerprint,
                    now_iso=now,
                )
            except LookupError as exc:
                raise StorageNotFoundError(str(exc)) from exc
            except ValueError as exc:
                if "mismatch" in str(exc) or "read-only" in str(exc):
                    raise StorageConflictError(str(exc)) from exc
                raise

            new_body = res["new_body"]
            new_sha = self.shim.sha256_hex(new_body)
            self.db.execute(
                "UPDATE notes SET body = ?, body_sha = ?, updated_at = ? WHERE id = ?",
                (new_body, new_sha, now, note_id),
            )
            self._insert_revision(
                note_id, note["title"], new_body, new_sha, reason=f"segment_edit:{seg_id}", now_iso=now
            )
            self._sync_note_resource_links(note_id, new_body)
            self._save_note_segments(note_id, res["updated_segments"], res["updated_orphans"])
            self._reanchor_note_annotations(note_id, new_body, now_iso=now)

        return {
            "note_id": note_id,
            "body_sha": new_sha,
            "delta": res["delta"],
            "segment": res["edited_segment"],
        }

    def reseed_note(self, note_id: str) -> dict[str, Any]:
        """Clear `needs_resync` on a note by relocating surviving segments/orphans and seeding uncovered lines."""
        with self.db.transaction():
            note = self.get_note(note_id, include_deleted=False, include_segments=True)
            if note is None:
                raise StorageNotFoundError(f"Note not found: {note_id}")
            lines = note["body"].split("\n")
            now = self.shim.now_iso()
            new_segs, kept_orphans, fresh_count = reseed_segments(
                note["segments"],
                note["orphans"],
                lines,
                note["title"],
                now_iso=now,
            )
            self._save_note_segments(note_id, new_segs, kept_orphans)
            self._reanchor_note_annotations(note_id, note["body"], now_iso=now)
            self.db.execute(
                "UPDATE notes SET needs_resync = 0, updated_at = ? WHERE id = ?",
                (now, note_id),
            )
        return {
            "note_id": note_id,
            "segments": len(new_segs),
            "fresh": fresh_count,
        }

    def update_segment_status(
        self, note_id: str, seg_id: int, status: str
    ) -> dict[str, Any]:
        if status not in ("todo", "active", "done", "skipped", "background", "container"):
            raise ValueError(f"Invalid segment status: {status!r}")
        with self.db.transaction():
            row = self.db.query_one(
                "SELECT * FROM segments WHERE note_id = ? AND seg_id = ?",
                (note_id, seg_id),
            )
            if row is None:
                raise StorageNotFoundError(f"Segment {seg_id} not found on note {note_id}")
            now = self.shim.now_iso()
            self.db.execute(
                "UPDATE segments SET status = ?, updated_at = ? WHERE note_id = ? AND seg_id = ?",
                (status, now, note_id, seg_id),
            )
        segs = self.get_note_segments(note_id)
        return next(s for s in segs if s["seg_id"] == seg_id)

    def record_segment_card(
        self, note_id: str, seg_id: int, anki_note_id: int, *, activate_if_todo: bool = True
    ) -> dict[str, Any]:
        """Link an Anki note ID to its source segment (idempotent) and transition `todo` -> `active`."""
        with self.db.transaction():
            seg_row = self.db.query_one(
                "SELECT * FROM segments WHERE note_id = ? AND seg_id = ?",
                (note_id, seg_id),
            )
            if seg_row is None:
                raise StorageNotFoundError(f"Segment {seg_id} not found on note {note_id}")
            existing = self.db.query_one(
                "SELECT id FROM segment_cards WHERE note_id = ? AND seg_id = ? AND anki_note_id = ?",
                (note_id, seg_id, anki_note_id),
            )
            if existing is None:
                self.db.execute(
                    "INSERT INTO segment_cards(note_id, seg_id, anki_note_id) VALUES(?, ?, ?)",
                    (note_id, seg_id, anki_note_id),
                )
            if activate_if_todo and seg_row["status"] == "todo":
                now = self.shim.now_iso()
                self.db.execute(
                    "UPDATE segments SET status = 'active', updated_at = ? WHERE note_id = ? AND seg_id = ?",
                    (now, note_id, seg_id),
                )
        segs = self.get_note_segments(note_id)
        return next(s for s in segs if s["seg_id"] == seg_id)

    def find_card_source(self, anki_note_id: int) -> dict[str, Any] | None:
        """Reverse provenance lookup: Anki `note_id` -> source note, segment, text, and ancestor breadcrumb."""
        hit = self.db.query_one(
            """
            SELECT sc.note_id, sc.seg_id
            FROM segment_cards sc
            JOIN notes n ON n.id = sc.note_id
            WHERE sc.anki_note_id = ?
            ORDER BY CASE WHEN n.deleted_at IS NULL THEN 0 ELSE 1 END, sc.id ASC
            LIMIT 1
            """,
            (anki_note_id,),
        )
        if hit is None:
            return None
        note = self.get_note(hit["note_id"], include_deleted=True, include_segments=True)
        if note is None:
            return None
        segs = note["segments"]
        by_id = {s["seg_id"]: s for s in segs}
        seg = by_id.get(int(hit["seg_id"]))
        if seg is None:
            return None

        trail: list[dict[str, Any]] = []
        cur: dict[str, Any] | None = seg
        seen: set[int] = set()
        while cur is not None and cur["seg_id"] not in seen:
            seen.add(cur["seg_id"])
            trail.append(cur)
            pid = cur.get("parent_seg_id")
            cur = by_id.get(int(pid)) if pid is not None else None
        trail.reverse()

        lines = note["body"].split("\n") if note["body"] else []
        a = max(1, min(int(seg["start_line"]), len(lines) or 1))
        b = max(a, min(int(seg["end_line"]), len(lines) or a))
        return {
            "note_id": note["id"],
            "title": note["title"],
            "legacy_path": note.get("legacy_path"),
            "note_deleted": note.get("deleted_at") is not None,
            "seg_id": seg["seg_id"],
            "status": seg["status"],
            "stale": seg["stale"],
            "line_start": a,
            "line_end": b,
            "fingerprint": seg["fingerprint"],
            "edit_revision": note["body_sha"],
            "text": "\n".join(lines[a - 1 : b]) if lines else (seg.get("first_line") or ""),
            "cards_created": list(seg["cards_created"]),
            "breadcrumb": [
                {
                    "seg_id": t["seg_id"],
                    "status": t["status"],
                    "title": t["title"],
                    "line_start": t["start_line"],
                    "line_end": t["end_line"],
                    "cards_created": list(t["cards_created"]),
                }
                for t in trail
            ],
        }

    def get_reading_round(self) -> dict[str, Any] | None:
        row = self.db.query_one("SELECT data FROM reading_round WHERE id = 1")
        if not row or not row["data"]:
            return None
        try:
            parsed = json.loads(row["data"])
            return parsed if isinstance(parsed, dict) else None
        except Exception:
            return None

    def set_reading_round(self, round_data: dict[str, Any] | None) -> None:
        with self.db.transaction():
            if round_data is None:
                self.db.execute("DELETE FROM reading_round WHERE id = 1")
            else:
                self.db.execute(
                    "INSERT INTO reading_round(id, data) VALUES(1, ?) "
                    "ON CONFLICT(id) DO UPDATE SET data = excluded.data",
                    (json.dumps(round_data, ensure_ascii=False),),
                )

    # ------------------------------------------------------------------
    # Stand-off AI Highlight & Comment Layer DAO
    # ------------------------------------------------------------------

    def _reanchor_note_annotations(
        self, note_id: str, new_body: str, *, now_iso: str | None = None
    ) -> list[dict[str, Any]]:
        """Re-anchor all existing AI annotations on `note_id` against `new_body`."""
        rows = self.db.query_all(
            "SELECT * FROM ai_annotations WHERE note_id = ? ORDER BY line_hint ASC, created_at ASC",
            (note_id,),
        )
        if not rows:
            return []
        now = now_iso or self.shim.now_iso()
        reanchored = reanchor_annotations(rows, new_body, now_iso=now)
        for old_row, new_row in zip(rows, reanchored):
            if (
                old_row["quote_exact"] != new_row["quote_exact"]
                or old_row["quote_prefix"] != new_row["quote_prefix"]
                or old_row["quote_suffix"] != new_row["quote_suffix"]
                or int(old_row["line_hint"]) != int(new_row["line_hint"])
                or old_row["status"] != new_row["status"]
            ):
                self.db.execute(
                    """
                    UPDATE ai_annotations
                    SET quote_exact = ?, quote_prefix = ?, quote_suffix = ?,
                        line_hint = ?, status = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (
                        new_row["quote_exact"],
                        new_row["quote_prefix"],
                        new_row["quote_suffix"],
                        int(new_row["line_hint"]),
                        new_row["status"],
                        now,
                        new_row["id"],
                    ),
                )
        return reanchored

    def list_annotations(
        self,
        note_id_or_path: str,
        *,
        status: str | None = "active",
        layer_name: str | None = None,
    ) -> list[dict[str, Any]]:
        """List AI highlight annotations for a note (by UUID or legacy path)."""
        note = self.resolve_note(note_id_or_path, include_deleted=True)
        if note is None:
            return []
        clauses = ["note_id = ?"]
        params: list[Any] = [note["id"]]
        if status is not None and status != "all":
            clauses.append("status = ?")
            params.append(status)
        if layer_name is not None:
            clauses.append("layer_name = ?")
            params.append(layer_name)
        where_sql = " AND ".join(clauses)
        return self.db.query_all(
            f"SELECT * FROM ai_annotations WHERE {where_sql} ORDER BY line_hint ASC, created_at ASC",
            params,
        )

    def add_annotations_batch(
        self,
        note_id_or_path: str,
        items: list[dict[str, Any]],
        *,
        layer_name: str = "default",
        replace_layer: bool = False,
    ) -> dict[str, Any]:
        """Anchor and batch-insert AI highlights & comments for a note.

        Each item in `items` accepts:
          - `quote` (or `quote_exact`): target substring to highlight
          - `comment` (optional): AI annotation note
          - `quote_prefix`, `quote_suffix`, `line_hint` (optional disambiguation hints)
          - `layer_name` (optional per-item override)

        Automatically aligns minor LLM quote discrepancies against the actual note body
        via `locate_quote_anchor`. Deduplicates identical quotes on the same layer.
        """
        with self.db.transaction():
            note = self.resolve_note(note_id_or_path, include_deleted=False)
            if note is None:
                raise StorageNotFoundError(f"Note not found: {note_id_or_path}")
            nid = note["id"]
            body = note["body"] or ""
            now = self.shim.now_iso()
            default_layer = (layer_name or "default").strip() or "default"

            if replace_layer:
                self.db.execute(
                    "DELETE FROM ai_annotations WHERE note_id = ? AND layer_name = ?",
                    (nid, default_layer),
                )

            existing_rows = self.db.query_all(
                "SELECT * FROM ai_annotations WHERE note_id = ?",
                (nid,),
            )
            by_key: dict[tuple[str, str, int], dict[str, Any]] = {
                (r["layer_name"], r["quote_exact"], int(r["line_hint"])): r
                for r in existing_rows
            }

            saved: list[dict[str, Any]] = []
            unmatched: list[dict[str, Any]] = []

            for idx, item in enumerate(items or []):
                raw_quote = str(
                    item.get("quote") or item.get("quote_exact") or ""
                ).strip()
                if not raw_quote:
                    unmatched.append({"index": idx, "quote": "", "reason": "empty_quote"})
                    continue
                comment = str(item.get("comment") or "").strip()
                item_layer = (
                    str(item.get("layer_name") or default_layer).strip() or default_layer
                )
                hint_line = item.get("line_hint")
                try:
                    hint_line_int = int(hint_line) if hint_line is not None else None
                except (TypeError, ValueError):
                    hint_line_int = None

                hit = locate_quote_anchor(
                    body,
                    raw_quote,
                    quote_prefix=str(item.get("quote_prefix") or ""),
                    quote_suffix=str(item.get("quote_suffix") or ""),
                    line_hint=hint_line_int,
                )
                if hit is None:
                    unmatched.append(
                        {
                            "index": idx,
                            "quote": raw_quote,
                            "reason": "quote_not_found_in_note",
                        }
                    )
                    continue

                exact = hit["quote_exact"]
                prefix = hit["quote_prefix"]
                suffix = hit["quote_suffix"]
                line_no = int(hit["line_hint"])
                dedup_key = (item_layer, exact, line_no)

                if dedup_key in by_key:
                    prev = by_key[dedup_key]
                    ann_id = prev["id"]
                    merged_comment = comment if comment else prev["comment"]
                    self.db.execute(
                        """
                        UPDATE ai_annotations
                        SET quote_prefix = ?, quote_suffix = ?, comment = ?,
                            status = 'active', updated_at = ?
                        WHERE id = ?
                        """,
                        (prefix, suffix, merged_comment, now, ann_id),
                    )
                    row = {
                        "id": ann_id,
                        "note_id": nid,
                        "layer_name": item_layer,
                        "quote_exact": exact,
                        "quote_prefix": prefix,
                        "quote_suffix": suffix,
                        "comment": merged_comment,
                        "line_hint": line_no,
                        "status": "active",
                        "match_tier": hit["tier"],
                        "confidence": hit["confidence"],
                        "created_at": prev["created_at"],
                        "updated_at": now,
                    }
                    by_key[dedup_key] = row
                    saved.append(row)
                else:
                    ann_id = str(item.get("id") or self.shim.new_id())
                    self.db.execute(
                        """
                        INSERT INTO ai_annotations(
                            id, note_id, layer_name, quote_exact, quote_prefix, quote_suffix,
                            comment, line_hint, status, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
                        """,
                        (
                            ann_id,
                            nid,
                            item_layer,
                            exact,
                            prefix,
                            suffix,
                            comment,
                            line_no,
                            now,
                            now,
                        ),
                    )
                    row = {
                        "id": ann_id,
                        "note_id": nid,
                        "layer_name": item_layer,
                        "quote_exact": exact,
                        "quote_prefix": prefix,
                        "quote_suffix": suffix,
                        "comment": comment,
                        "line_hint": line_no,
                        "status": "active",
                        "match_tier": hit["tier"],
                        "confidence": hit["confidence"],
                        "created_at": now,
                        "updated_at": now,
                    }
                    by_key[dedup_key] = row
                    saved.append(row)

        return {
            "note_id": nid,
            "path": note["path"],
            "title": note["title"],
            "saved_count": len(saved),
            "unmatched_count": len(unmatched),
            "saved": saved,
            "unmatched": unmatched,
        }

    def delete_annotations(
        self,
        *,
        note_id_or_path: str | None = None,
        annotation_id: str | None = None,
        layer_name: str | None = None,
    ) -> int:
        """Delete AI annotations by `annotation_id`, `note_id_or_path`, and/or `layer_name`."""
        clauses: list[str] = []
        params: list[Any] = []
        if annotation_id is not None:
            clauses.append("id = ?")
            params.append(annotation_id)
        if note_id_or_path is not None:
            note = self.resolve_note(note_id_or_path, include_deleted=True)
            if note is None:
                return 0
            clauses.append("note_id = ?")
            params.append(note["id"])
        if layer_name is not None:
            clauses.append("layer_name = ?")
            params.append(layer_name)
        if not clauses:
            raise ValueError("Must specify at least one filter to delete annotations")
        where_sql = " AND ".join(clauses)
        with self.db.transaction():
            return self.db.execute(
                f"DELETE FROM ai_annotations WHERE {where_sql}", params
            )

    # ------------------------------------------------------------------
    # Atomic File / Notebook Operation Log (Replaces file_relocation.py)
    # ------------------------------------------------------------------

    def record_file_operation(
        self,
        action: str,
        old_path: str,
        new_path: str,
        *,
        is_dir: bool = False,
        target_id: str | None = None,
        request_id: str | None = None,
        request_payload: dict[str, Any] | None = None,
        operation_id: str | None = None,
    ) -> dict[str, Any]:
        op_id = operation_id or request_id or self.shim.new_id()
        now = self.shim.now_iso()
        req_json = (
            json.dumps(request_payload, ensure_ascii=False, sort_keys=True)
            if request_payload is not None
            else None
        )
        with self.db.transaction():
            self.db.execute(
                """
                INSERT INTO file_operations(
                    operation_id, request_id, action, old_path, new_path,
                    is_dir, target_id, undone, request_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                ON CONFLICT(operation_id) DO UPDATE SET
                    request_id = COALESCE(excluded.request_id, file_operations.request_id),
                    action = excluded.action,
                    old_path = excluded.old_path,
                    new_path = excluded.new_path,
                    is_dir = excluded.is_dir,
                    target_id = excluded.target_id,
                    request_json = COALESCE(excluded.request_json, file_operations.request_json)
                """,
                (
                    op_id,
                    request_id,
                    action,
                    old_path,
                    new_path,
                    1 if is_dir else 0,
                    target_id,
                    req_json,
                    now,
                ),
            )
        return self.get_file_operation(op_id)  # type: ignore[return-value]

    def get_file_operation(self, operation_id: str) -> dict[str, Any] | None:
        row = self.db.query_one(
            "SELECT * FROM file_operations WHERE operation_id = ?", (operation_id,)
        )
        if row is None:
            return None
        d = dict(row)
        d["is_dir"] = bool(d["is_dir"])
        d["undone"] = bool(d["undone"])
        try:
            d["request"] = json.loads(d["request_json"]) if d.get("request_json") else None
        except Exception:
            d["request"] = None
        return d

    def get_file_operation_by_request(self, request_id: str) -> dict[str, Any] | None:
        row = self.db.query_one(
            "SELECT * FROM file_operations WHERE request_id = ? OR operation_id = ? LIMIT 1",
            (request_id, request_id),
        )
        if row is None:
            return None
        return self.get_file_operation(row["operation_id"])

    def mark_file_operation_undone(self, operation_id: str) -> None:
        with self.db.transaction():
            self.db.execute(
                "UPDATE file_operations SET undone = 1 WHERE operation_id = ?",
                (operation_id,),
            )

