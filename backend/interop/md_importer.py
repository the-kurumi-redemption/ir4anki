"""Joplin-style two-stage Markdown importer writing directly to StorageEngine (SSOT).

Workflow:
- Pre-scan & partition:
  - Validates relative paths against traversal (hard 400).
  - Non-blocking skip + warning for system/hidden files, unsupported extensions,
    0-byte empty files, and invalid UTF-8 Markdown files.
  - Strips UTF-8 BOM (`\ufeff`) and normalizes line endings (`\n`).
- Stage 1 (In-memory Note & Conflict Planning):
  - Checks conflicts solely against `StorageEngine` (`notes.legacy_path`), never scanning `NOTES_DIR`.
  - Under `on_conflict='error'`, raises `ImportConflictError` before writing ANY blob or DB row.
  - Allocates unique `legacy_path` for `rename` (`stem (1).md`, ...) and pre-allocates UUIDs.
  - Naturally skips empty directories (notebooks are created only for imported notes).
- Stage 2 (On-Demand Resource Ingestion & Single-Pass Persistence):
  - Rewrites Markdown & HTML local image references to `:/<resource_id>` using `links.rewrite_local_links`.
  - Ingests ONLY images actually referenced by imported Markdown notes into `media/<id>.<ext>`
    via `engine.put_resource(..., deduplicate=True)` (SHA-256 deduplicated).
  - Unreferenced junk images in a mixed folder are skipped (recorded in `result.skipped`),
    unless the batch contains exclusively standalone images.
  - Persists each note in ONE atomic call (`create_note` or `update_note`), populating
    `note_resources` completely so `gc_unreferenced_resources()` never deletes imported images.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import posixpath
from typing import Sequence

from storage.domain import extract_resource_ids
from storage.engine import StorageEngine

from .base import (
    BaseImporter,
    is_system_or_hidden_path,
    normalize_import_rel_path,
    normalize_target_dir,
)
from .links import rewrite_local_links
from .types import (
    ImportConflictError,
    ImportFile,
    ImportModuleMeta,
    ImportOptions,
    ImportResult,
    ImportValidationError,
    ImportedNoteItem,
    ImportedResourceItem,
    NOTE_IMAGE_EXTS,
    SkippedImportItem,
)


@dataclass(slots=True)
class _MdCandidate:
    orig_rel: str
    dest_rel: str
    text: str
    action: str = "written"
    existing_note_id: str | None = None
    planned_note_id: str | None = None


class MarkdownImporter(BaseImporter):
    """Two-stage Markdown + on-demand local image importer backed by StorageEngine."""

    meta = ImportModuleMeta(
        format="md",
        description="Markdown 笔记与关联图片（Joplin 模式两阶段导入）",
        file_extensions=(".md", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".avif"),
        supports_directory=True,
    )

    def import_files(
        self,
        engine: StorageEngine,
        files: Sequence[ImportFile],
        options: ImportOptions,
    ) -> ImportResult:
        if options.on_conflict not in ("error", "overwrite", "rename", "skip"):
            raise ImportValidationError("on_conflict 非法", status_code=400)
        if not files:
            raise ImportValidationError("没有上传任何文件", status_code=400)

        target_dir = normalize_target_dir(options.target_dir)
        result = ImportResult()

        md_candidates: list[_MdCandidate] = []
        image_candidates: dict[str, ImportFile] = {}
        seen_batch_paths: set[str] = set()

        # ---- Pre-scan, security validate & partition ----
        for item in files:
            norm_rel = normalize_import_rel_path(item.rel_path)

            if norm_rel in seen_batch_paths:
                raise ImportValidationError(f"批内重复目标：{norm_rel}", status_code=409)
            seen_batch_paths.add(norm_rel)

            sys_reason = is_system_or_hidden_path(norm_rel)
            if sys_reason is not None:
                result.skipped.append(SkippedImportItem(path=norm_rel, reason=sys_reason))
                continue

            suffix = Path(norm_rel).suffix.lower()
            dir_parts = norm_rel.split("/")[:-1]
            if suffix == ".md":
                if "_assets" in dir_parts:
                    result.skipped.append(
                        SkippedImportItem(path=norm_rel, reason="资源目录（_assets）内的文档，已跳过")
                    )
                    continue
                if not item.data:
                    result.skipped.append(SkippedImportItem(path=norm_rel, reason="空文件，已跳过"))
                    continue
                try:
                    decoded = item.data.decode("utf-8")
                except UnicodeDecodeError:
                    msg = f"{norm_rel}: 不是有效的 UTF-8 文本，已跳过"
                    result.warnings.append(msg)
                    result.skipped.append(SkippedImportItem(path=norm_rel, reason="非 UTF-8 编码，已跳过"))
                    continue
                if options.strip_bom and decoded.startswith("\ufeff"):
                    decoded = decoded.lstrip("\ufeff")
                decoded = decoded.replace("\r\n", "\n").replace("\r", "\n")
                if not decoded.strip():
                    result.skipped.append(SkippedImportItem(path=norm_rel, reason="空白笔记，已跳过"))
                    continue
                dest_rel = f"{target_dir}/{norm_rel}" if target_dir else norm_rel
                md_candidates.append(_MdCandidate(orig_rel=norm_rel, dest_rel=dest_rel, text=decoded))
            elif suffix in NOTE_IMAGE_EXTS:
                if not item.data:
                    result.skipped.append(SkippedImportItem(path=norm_rel, reason="空图片文件，已跳过"))
                    result.warnings.append(f"{norm_rel}: 空图片文件，已跳过")
                    continue
                image_candidates[norm_rel] = ImportFile(
                    rel_path=norm_rel,
                    data=item.data,
                    content_type=item.content_type,
                )
            else:
                result.skipped.append(
                    SkippedImportItem(path=norm_rel, reason="不支持的文件类型，已跳过")
                )

        # ---- Stage 1: Plan notes & resolve conflicts against StorageEngine ----
        conflicts: list[str] = []
        reserved_dests: set[str] = {c.dest_rel for c in md_candidates}
        allocated_dests: set[str] = set()

        def _exists_dest(candidate_rel: str) -> bool:
            if candidate_rel in allocated_dests:
                return True
            return engine.get_note_by_legacy_path(candidate_rel, include_deleted=False) is not None

        def _free_dest(base_rel: str) -> str:
            parent = posixpath.dirname(base_rel)
            name = posixpath.basename(base_rel)
            stem = Path(name).stem
            ext = Path(name).suffix
            idx = 1
            while True:
                cand_name = f"{stem} ({idx}){ext}"
                cand_rel = f"{parent}/{cand_name}" if parent else cand_name
                if cand_rel not in reserved_dests and not _exists_dest(cand_rel):
                    return cand_rel
                idx += 1

        for cand in md_candidates:
            existing = engine.get_note_by_legacy_path(cand.dest_rel, include_deleted=False)
            if existing is not None or cand.dest_rel in allocated_dests:
                if options.on_conflict == "error":
                    conflicts.append(cand.orig_rel)
                elif options.on_conflict == "skip":
                    cand.action = "skipped"
                    cand.existing_note_id = existing["id"] if existing else None
                elif options.on_conflict == "overwrite" and existing is not None:
                    cand.action = "overwritten"
                    cand.existing_note_id = existing["id"]
                    allocated_dests.add(cand.dest_rel)
                else:  # rename
                    new_dest = _free_dest(cand.dest_rel)
                    cand.dest_rel = new_dest
                    cand.action = "renamed"
                    cand.planned_note_id = engine.shim.new_id()
                    allocated_dests.add(new_dest)
            else:
                cand.action = "written"
                cand.planned_note_id = engine.shim.new_id()
                allocated_dests.add(cand.dest_rel)

        if conflicts:
            raise ImportConflictError(conflicts)

        # Build basename index for unambiguous bare-filename lookup (e.g. `![](pic.png)`)
        images_by_basename: dict[str, list[str]] = {}
        for img_rel in image_candidates:
            bname = posixpath.basename(img_rel).lower()
            images_by_basename.setdefault(bname, []).append(img_rel)

        # ---- Stage 2: On-demand resource ingestion & single-pass note persistence ----
        ingested_by_rel: dict[str, dict] = {}
        referenced_image_rels: set[str] = set()

        def _ingest_image(img_rel: str) -> str:
            referenced_image_rels.add(img_rel)
            cached = ingested_by_rel.get(img_rel)
            if cached is not None:
                return f":/{cached['id']}"
            img_file = image_candidates[img_rel]
            filename = Path(img_rel).name
            res = engine.put_resource(
                filename,
                img_file.data,
                deduplicate=True,
                legacy_name=None,
            )
            ingested_by_rel[img_rel] = res
            result.imported_resources.append(
                ImportedResourceItem(
                    resource_id=res["id"],
                    original=img_rel,
                    filename=res["filename"],
                    reused=bool(res.get("deduplicated", False)),
                )
            )
            return f":/{res['id']}"

        def _match_image(source_rel: str, norm_rel: str, decoded_path: str) -> str | None:
            # 1. Exact relative match within the uploaded batch
            if norm_rel in image_candidates:
                return norm_rel
            # 2. Case-insensitive relative match (handles Windows/macOS authoring differences)
            norm_lower = norm_rel.lower()
            for cand_rel in image_candidates:
                if cand_rel.lower() == norm_lower:
                    return cand_rel
            # 3. For bare filenames without path separators (e.g. `![](pic.png)`),
            #    check `<note_dir>/_assets/<name>`, then unique basename within the batch.
            clean_decoded = decoded_path.replace("\\", "/")
            if "/" not in clean_decoded:
                note_dir = posixpath.dirname(source_rel)
                assets_cand = f"{note_dir}/_assets/{clean_decoded}" if note_dir else f"_assets/{clean_decoded}"
                if assets_cand in image_candidates:
                    return assets_cand
                hits = images_by_basename.get(clean_decoded.lower())
                if hits and len(hits) == 1:
                    return hits[0]
            return None

        for cand in md_candidates:
            title = Path(cand.dest_rel).stem
            if cand.action == "skipped":
                result.imported_notes.append(
                    ImportedNoteItem(
                        note_id=cand.existing_note_id,
                        path=cand.dest_rel,
                        original=cand.orig_rel,
                        action="skipped",
                        title=title,
                        resources_linked=0,
                    )
                )
                result.skipped.append(
                    SkippedImportItem(path=cand.orig_rel, reason="同名笔记已存在，按策略跳过")
                )
                continue

            def _resolve_for_note(norm_rel: str, decoded_path: str, _src: str = cand.orig_rel) -> str | None:
                matched_rel = _match_image(_src, norm_rel, decoded_path)
                if matched_rel is None:
                    return None
                return _ingest_image(matched_rel)

            rewritten_body, missing_refs = rewrite_local_links(
                cand.text,
                cand.orig_rel,
                _resolve_for_note,
            )
            for ref in missing_refs:
                result.warnings.append(f"{cand.orig_rel}: 未找到本地图片引用 {ref}")

            if cand.action == "overwritten" and cand.existing_note_id:
                saved_note = engine.update_note(
                    cand.existing_note_id,
                    body=rewritten_body,
                    reason="import_overwrite",
                )
            else:
                nb_dir = posixpath.dirname(cand.dest_rel)
                nb_id = engine.resolve_or_create_notebook_path(nb_dir) if nb_dir else None
                saved_note = engine.create_note(
                    title,
                    rewritten_body,
                    notebook_id=nb_id,
                    note_id=cand.planned_note_id,
                    in_list=False,
                    seed_segments=False,
                    legacy_path=cand.dest_rel,
                    record_initial_revision=True,
                )

            linked_count = len(extract_resource_ids(saved_note["body"]))
            result.imported_notes.append(
                ImportedNoteItem(
                    note_id=saved_note["id"],
                    path=saved_note["path"],
                    original=cand.orig_rel,
                    action=cand.action,
                    title=saved_note["title"],
                    resources_linked=linked_count,
                )
            )

        # ---- Handle remaining images ----
        if not md_candidates and options.import_standalone_images:
            # Explicit standalone image upload (no Markdown files in this batch)
            for img_rel in sorted(image_candidates):
                _ingest_image(img_rel)
        else:
            # Mixed folder upload: skip unreferenced junk images so media/ stays clean
            for img_rel in sorted(image_candidates):
                if img_rel not in referenced_image_rels:
                    result.skipped.append(
                        SkippedImportItem(path=img_rel, reason="未被任何笔记正文引用，未入库")
                    )

        return result
