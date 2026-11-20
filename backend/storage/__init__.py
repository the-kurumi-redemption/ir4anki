"""Joplin-mode Storage Engine package for ir4anki (Stage 1: Data Layer & DAO).

Exports:
- Drivers & Shims: `DatabaseDriver`, `SQLiteDatabaseDriver`, `FsDriver`, `LocalFsDriver`, `MemoryFsDriver`, `PlatformShim`
- Schema: `SCHEMA_VERSION`, `ensure_schema`
- Domain: `seed_whole_note`, `reanchor_segments`, `reseed_segments`, `compute_bookmark_split`, `apply_segment_edit`, `extract_resource_ids`
- Engine / DAO: `StorageEngine`, `StorageConflictError`, `StorageNotFoundError`, `open_storage_engine`
"""
from __future__ import annotations

from pathlib import Path

from .domain import (
    apply_segment_edit,
    compute_bookmark_split,
    extract_resource_ids,
    infer_note_title,
    next_seg_id,
    normalize_newlines,
    reading_worthwhile,
    reanchor_segments,
    relocate_span,
    reseed_segments,
    seed_whole_note,
    seg_fingerprint,
)
from .drivers import (
    DatabaseDriver,
    FsDriver,
    LocalFsDriver,
    MemoryFsDriver,
    PlatformShim,
    SQLiteDatabaseDriver,
)
from .engine import StorageConflictError, StorageEngine, StorageNotFoundError
from .migration import LegacyMigrator
from .schema import SCHEMA_VERSION, ensure_schema


def open_storage_engine(
    data_dir: str | Path | None = None,
    *,
    in_memory: bool = False,
) -> StorageEngine:
    """Factory helper to open a disk-backed or in-memory `StorageEngine`."""
    if in_memory:
        return StorageEngine(
            db=SQLiteDatabaseDriver(":memory:"),
            fs=MemoryFsDriver(),
            shim=PlatformShim(),
        )
    root = Path(data_dir or (Path.home() / ".local" / "share" / "ir4anki")).resolve()
    root.mkdir(parents=True, exist_ok=True)
    db_path = root / "data.db"
    media_dir = root / "media"
    return StorageEngine(
        db=SQLiteDatabaseDriver(db_path),
        fs=LocalFsDriver(media_dir),
        shim=PlatformShim(),
    )


__all__ = [
    "DatabaseDriver",
    "SQLiteDatabaseDriver",
    "FsDriver",
    "LocalFsDriver",
    "MemoryFsDriver",
    "PlatformShim",
    "SCHEMA_VERSION",
    "ensure_schema",
    "StorageEngine",
    "StorageConflictError",
    "StorageNotFoundError",
    "LegacyMigrator",
    "open_storage_engine",
    "normalize_newlines",
    "reading_worthwhile",
    "infer_note_title",
    "seg_fingerprint",
    "seed_whole_note",
    "next_seg_id",
    "relocate_span",
    "reanchor_segments",
    "reseed_segments",
    "compute_bookmark_split",
    "apply_segment_edit",
    "extract_resource_ids",
]
