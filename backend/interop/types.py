"""Data structures and error types for Joplin-style InteropService."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal

ConflictPolicy = Literal["error", "overwrite", "rename", "skip"]

NOTE_IMAGE_EXTS: frozenset[str] = frozenset(
    {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".avif"}
)

SYSTEM_SKIP_DIRS: frozenset[str] = frozenset(
    {".git", ".obsidian", ".trash", "node_modules", "__pycache__"}
)


class ImportValidationError(Exception):
    """Protocol or security validation error (4xx HTTP status)."""

    def __init__(self, detail: str, *, status_code: int = 400) -> None:
        super().__init__(detail)
        self.detail = detail
        self.status_code = status_code


class ImportConflictError(Exception):
    """Raised when `on_conflict == 'error'` encounters existing destination notes."""

    def __init__(self, conflicts: list[str]) -> None:
        super().__init__(f"Import conflicts: {', '.join(conflicts)}")
        self.conflicts = list(conflicts)


@dataclass(slots=True)
class ImportFile:
    """One file payload submitted to an importer."""

    rel_path: str
    data: bytes
    content_type: str | None = None


@dataclass(slots=True)
class ImportOptions:
    """Execution options shared across importers."""

    target_dir: str = ""
    on_conflict: ConflictPolicy = "error"
    format: str = "md"
    strip_bom: bool = True
    import_standalone_images: bool = True


@dataclass(slots=True)
class ImportModuleMeta:
    """Declarative metadata describing one registered importer module."""

    format: str
    description: str
    file_extensions: tuple[str, ...]
    supports_directory: bool = True

    def to_dict(self) -> dict[str, Any]:
        return {
            "format": self.format,
            "description": self.description,
            "file_extensions": list(self.file_extensions),
            "supports_directory": self.supports_directory,
        }


@dataclass(slots=True)
class ImportedNoteItem:
    """Outcome for one Markdown note processed by an importer."""

    note_id: str | None
    path: str
    original: str
    action: str  # written | overwritten | renamed | skipped
    title: str
    resources_linked: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "note_id": self.note_id,
            "path": self.path,
            "original": self.original,
            "action": self.action,
            "title": self.title,
            "resources_linked": self.resources_linked,
        }


@dataclass(slots=True)
class ImportedResourceItem:
    """Outcome for one media resource stored in the flat sandbox."""

    resource_id: str
    original: str
    filename: str
    reused: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "resource_id": self.resource_id,
            "original": self.original,
            "filename": self.filename,
            "reused": self.reused,
        }


@dataclass(slots=True)
class SkippedImportItem:
    """One file skipped during non-blocking import."""

    path: str
    reason: str

    def to_dict(self) -> dict[str, Any]:
        return {"path": self.path, "reason": self.reason}


@dataclass(slots=True)
class ImportResult:
    """Unified Joplin-style import summary returned by InteropService."""

    imported_notes: list[ImportedNoteItem] = field(default_factory=list)
    imported_resources: list[ImportedResourceItem] = field(default_factory=list)
    skipped: list[SkippedImportItem] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def summary_dict(self) -> dict[str, int]:
        notes_written = sum(1 for n in self.imported_notes if n.action == "written")
        notes_overwritten = sum(1 for n in self.imported_notes if n.action == "overwritten")
        notes_renamed = sum(1 for n in self.imported_notes if n.action == "renamed")
        notes_skipped = sum(1 for n in self.imported_notes if n.action == "skipped")
        res_reused = sum(1 for r in self.imported_resources if r.reused)
        res_new = len(self.imported_resources) - res_reused
        return {
            "notes_imported": notes_written + notes_overwritten + notes_renamed,
            "notes_written": notes_written,
            "notes_overwritten": notes_overwritten,
            "notes_renamed": notes_renamed,
            "notes_skipped": notes_skipped,
            "resources_imported": len(self.imported_resources),
            "resources_new": res_new,
            "resources_reused": res_reused,
            "skipped": len(self.skipped),
            "warnings": len(self.warnings),
        }

    def legacy_saved_list(self) -> list[dict[str, Any]]:
        """Backwards-compatible `saved` array for existing UI / callers."""
        out: list[dict[str, Any]] = []
        for n in self.imported_notes:
            entry: dict[str, Any] = {
                "path": n.original if n.action == "skipped" else n.path,
                "action": n.action,
                "original": n.original,
            }
            if n.note_id:
                entry["note_id"] = n.note_id
            out.append(entry)
        for r in self.imported_resources:
            out.append(
                {
                    "path": f":/{r.resource_id}",
                    "action": "reused" if r.reused else "written",
                    "original": r.original,
                    "resource_id": r.resource_id,
                }
            )
        return out

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": True,
            "imported_notes": [n.to_dict() for n in self.imported_notes],
            "imported_resources": [r.to_dict() for r in self.imported_resources],
            "skipped": [s.to_dict() for s in self.skipped],
            "warnings": list(self.warnings),
            "summary": self.summary_dict(),
            "saved": self.legacy_saved_list(),
            "images_renamed": {},
        }
