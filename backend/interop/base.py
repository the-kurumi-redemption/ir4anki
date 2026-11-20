"""BaseImporter abstraction and shared path validation utilities."""
from __future__ import annotations

from abc import ABC, abstractmethod
import posixpath
from typing import Sequence

from storage.engine import StorageEngine

from .types import (
    ImportFile,
    ImportModuleMeta,
    ImportOptions,
    ImportResult,
    ImportValidationError,
    SYSTEM_SKIP_DIRS,
)


def normalize_target_dir(target_dir: str) -> str:
    """Validate and normalize a target notebook directory path (empty string = root)."""
    raw = (target_dir or "").strip().replace("\\", "/")
    if not raw or raw == "/":
        return ""
    if "\x00" in raw:
        raise ImportValidationError("目标目录包含非法字符")
    if raw.startswith("/") or (len(raw) >= 2 and raw[1] == ":"):
        raise ImportValidationError("目标目录必须是相对路径")
    parts = [p for p in raw.split("/") if p]
    clean_parts: list[str] = []
    for part in parts:
        if part in (".", ".."):
            raise ImportValidationError("目标目录不能包含路径穿越")
        if part.startswith(".") or part in SYSTEM_SKIP_DIRS or part == "_assets":
            raise ImportValidationError("该目录受保护，不能作为导入目标")
        clean_parts.append(part)
    return "/".join(clean_parts)


def normalize_import_rel_path(rel_path: str) -> str:
    """Validate and normalize one uploaded file's relative path (POSIX style).

    Rejects empty paths, absolute paths, drive prefixes, null bytes, and upward
    traversal (`..`). Does NOT reject nested `_assets/` or system directories here;
    importers classify system/hidden directories as non-blocking skips.
    """
    raw = (rel_path or "").strip().replace("\\", "/")
    if not raw:
        raise ImportValidationError("缺少相对路径")
    if "\x00" in raw:
        raise ImportValidationError(f"路径包含非法字符：{rel_path}")
    if raw.startswith("/") or (len(raw) >= 2 and raw[1] == ":"):
        raise ImportValidationError(f"上传路径必须是相对路径：{rel_path}")
    raw_parts = [p for p in raw.split("/") if p and p != "."]
    if not raw_parts:
        raise ImportValidationError("缺少相对路径")
    if any(p == ".." for p in raw_parts):
        raise ImportValidationError(f"非法路径（禁止上级目录穿越）：{rel_path}")
    norm = posixpath.normpath("/".join(raw_parts))
    if norm in ("", ".", "..") or norm.startswith("../"):
        raise ImportValidationError(f"非法路径：{rel_path}")
    return norm


def is_system_or_hidden_path(norm_rel: str) -> str | None:
    """Return a skip reason if `norm_rel` resides in a system directory or is a dotfile."""
    parts = norm_rel.split("/")
    for part in parts[:-1]:
        if part in SYSTEM_SKIP_DIRS or part.startswith("."):
            return "系统或配置目录，已跳过"
    name = parts[-1]
    if name.startswith("."):
        return "隐藏或系统文件，已跳过"
    return None


class BaseImporter(ABC):
    """Abstract base class for Joplin-style format importers."""

    meta: ImportModuleMeta

    @abstractmethod
    def import_files(
        self,
        engine: StorageEngine,
        files: Sequence[ImportFile],
        options: ImportOptions,
    ) -> ImportResult:
        """Import `files` directly into `engine` (`data.db` + flat `media/` sandbox)."""
