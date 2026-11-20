"""Centralized Joplin-style InteropService registry and dispatcher."""
from __future__ import annotations

from typing import Any, Sequence

from storage.engine import StorageEngine

from .base import BaseImporter
from .md_importer import MarkdownImporter
from .types import ImportFile, ImportOptions, ImportResult, ImportValidationError


class InteropService:
    """Registry and dispatcher for all import modules."""

    def __init__(self) -> None:
        self._importers: dict[str, BaseImporter] = {}

    def register(self, importer: BaseImporter) -> None:
        key = (importer.meta.format or "").strip().lower()
        if not key:
            raise ValueError("Importer format cannot be empty")
        self._importers[key] = importer

    def list_modules(self) -> list[dict[str, Any]]:
        return [imp.meta.to_dict() for imp in self._importers.values()]

    def get_importer(self, fmt: str = "md") -> BaseImporter:
        key = (fmt or "md").strip().lower()
        imp = self._importers.get(key)
        if imp is None:
            raise ImportValidationError(f"不支持的导入格式：{fmt}", status_code=400)
        return imp

    def import_files(
        self,
        engine: StorageEngine,
        files: Sequence[ImportFile],
        options: ImportOptions | None = None,
    ) -> ImportResult:
        opts = options or ImportOptions()
        importer = self.get_importer(opts.format)
        return importer.import_files(engine, files, opts)


_default_service: InteropService | None = None


def get_default_interop_service() -> InteropService:
    """Return the process-wide InteropService pre-registered with built-in importers."""
    global _default_service
    if _default_service is None:
        svc = InteropService()
        svc.register(MarkdownImporter())
        _default_service = svc
    return _default_service
