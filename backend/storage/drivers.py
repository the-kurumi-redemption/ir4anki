"""Driver & Shim abstractions for ir4anki storage engine.

Follows Joplin's DatabaseDriver / FsDriver / PlatformShim separation:
- Core business logic and DAO depend ONLY on these abstract interfaces.
- Desktop / Server Python implementations use stdlib sqlite3 and pathlib/os.
- In-memory implementations allow ultra-fast unit testing and isolated sandboxes.
- Future mobile/cross-platform forks (e.g. Capacitor/Tauri/React Native) can
  implement equivalent drivers while preserving 100% of schema and DAO semantics.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import sqlite3
import tempfile
import uuid
from abc import ABC, abstractmethod
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Iterator, Sequence


class DatabaseDriver(ABC):
    """Abstract relational database driver (SQLite dialect)."""

    @abstractmethod
    def execute(self, sql: str, params: Sequence[Any] = ()) -> int:
        """Execute a write statement and return affected row count."""

    @abstractmethod
    def executemany(self, sql: str, seq_of_params: Sequence[Sequence[Any]]) -> int:
        """Execute a parameterized write statement across multiple parameter sets."""

    @abstractmethod
    def executescript(self, sql_script: str) -> None:
        """Execute a multi-statement SQL DDL/migration script."""

    @abstractmethod
    def query_one(self, sql: str, params: Sequence[Any] = ()) -> dict[str, Any] | None:
        """Execute a SELECT and return the first row as a dict, or None."""

    @abstractmethod
    def query_all(self, sql: str, params: Sequence[Any] = ()) -> list[dict[str, Any]]:
        """Execute a SELECT and return all rows as a list of dicts."""

    @abstractmethod
    @contextmanager
    def transaction(self) -> Iterator[None]:
        """Provide an atomic transaction scope (supports nesting via savepoints)."""

    @abstractmethod
    def vacuum_into(self, target_path: str | Path) -> None:
        """Create a consistent hot backup of the database at target_path."""

    @abstractmethod
    def integrity_check(self) -> tuple[bool, list[str]]:
        """Run PRAGMA integrity_check and PRAGMA foreign_key_check."""

    @abstractmethod
    def close(self) -> None:
        """Close underlying database connection(s)."""


class SQLiteDatabaseDriver(DatabaseDriver):
    """Stdlib sqlite3 driver with WAL mode, foreign keys, and nested savepoints."""

    def __init__(self, db_path: str | Path, *, timeout: float = 30.0) -> None:
        self.db_path = str(db_path)
        if self.db_path != ":memory:" and not self.db_path.startswith("file:"):
            Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(
            self.db_path,
            timeout=timeout,
            isolation_level=None,  # autocommit mode; explicit transactions managed by us
            check_same_thread=False,
        )
        self._conn.row_factory = sqlite3.Row
        self._tx_depth = 0
        self._sp_counter = 0
        self._configure_pragmas()

    def _configure_pragmas(self) -> None:
        if self.db_path != ":memory:":
            self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA synchronous=NORMAL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._conn.execute("PRAGMA busy_timeout=10000")

    def execute(self, sql: str, params: Sequence[Any] = ()) -> int:
        cur = self._conn.execute(sql, tuple(params))
        return cur.rowcount if cur.rowcount is not None else 0

    def executemany(self, sql: str, seq_of_params: Sequence[Sequence[Any]]) -> int:
        cur = self._conn.executemany(sql, [tuple(p) for p in seq_of_params])
        return cur.rowcount if cur.rowcount is not None else 0

    def executescript(self, sql_script: str) -> None:
        if self._tx_depth > 0:
            raise RuntimeError("executescript cannot be called inside an active transaction")
        self._conn.executescript(sql_script)
        # Re-assert foreign_keys after executescript just in case
        self._conn.execute("PRAGMA foreign_keys=ON")

    def query_one(self, sql: str, params: Sequence[Any] = ()) -> dict[str, Any] | None:
        cur = self._conn.execute(sql, tuple(params))
        row = cur.fetchone()
        return dict(row) if row is not None else None

    def query_all(self, sql: str, params: Sequence[Any] = ()) -> list[dict[str, Any]]:
        cur = self._conn.execute(sql, tuple(params))
        return [dict(r) for r in cur.fetchall()]

    @contextmanager
    def transaction(self) -> Iterator[None]:
        if self._tx_depth == 0:
            self._conn.execute("BEGIN IMMEDIATE")
            self._tx_depth = 1
            try:
                yield
            except BaseException:
                self._tx_depth = 0
                if self._conn.in_transaction:
                    self._conn.execute("ROLLBACK")
                raise
            else:
                self._tx_depth = 0
                if self._conn.in_transaction:
                    self._conn.execute("COMMIT")
        else:
            self._sp_counter += 1
            sp_name = f"sp_{self._tx_depth}_{self._sp_counter}"
            self._conn.execute(f"SAVEPOINT {sp_name}")
            self._tx_depth += 1
            try:
                yield
            except BaseException:
                self._tx_depth -= 1
                self._conn.execute(f"ROLLBACK TO SAVEPOINT {sp_name}")
                self._conn.execute(f"RELEASE SAVEPOINT {sp_name}")
                raise
            else:
                self._tx_depth -= 1
                self._conn.execute(f"RELEASE SAVEPOINT {sp_name}")

    def vacuum_into(self, target_path: str | Path) -> None:
        target = Path(target_path).resolve()
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            target.unlink()
        escaped = str(target).replace("'", "''")
        self._conn.execute(f"VACUUM INTO '{escaped}'")

    def integrity_check(self) -> tuple[bool, list[str]]:
        issues: list[str] = []
        rows = self._conn.execute("PRAGMA integrity_check").fetchall()
        for r in rows:
            val = r[0]
            if val != "ok":
                issues.append(f"integrity_check: {val}")
        fk_rows = self._conn.execute("PRAGMA foreign_key_check").fetchall()
        for r in fk_rows:
            issues.append(f"foreign_key_check: table={r[0]} rowid={r[1]} parent={r[2]} fkid={r[3]}")
        return (len(issues) == 0), issues

    def close(self) -> None:
        self._conn.close()


class FsDriver(ABC):
    """Abstract sandbox filesystem driver for flat media/resource blobs."""

    @abstractmethod
    def write_bytes(self, rel_path: str, data: bytes) -> None:
        """Atomically write bytes to rel_path inside the sandbox."""

    @abstractmethod
    def read_bytes(self, rel_path: str) -> bytes:
        """Read bytes from rel_path inside the sandbox; raise FileNotFoundError if missing."""

    @abstractmethod
    def exists(self, rel_path: str) -> bool:
        """Return True if rel_path exists as a regular file inside the sandbox."""

    @abstractmethod
    def delete(self, rel_path: str) -> bool:
        """Delete rel_path if it exists; return True if deleted, False if missing."""

    @abstractmethod
    def stat_size(self, rel_path: str) -> int:
        """Return size in bytes of rel_path; raise FileNotFoundError if missing."""

    @abstractmethod
    def list_files(self) -> list[str]:
        """List all relative file names stored in the sandbox."""

    @abstractmethod
    def resolve_local_path(self, rel_path: str) -> Path | None:
        """Return host Path for zero-copy static serving (e.g. FastAPI FileResponse), or None if virtual."""

    @abstractmethod
    def copy_all_to(self, target_dir: str | Path) -> None:
        """Copy all sandbox files to target_dir for backup/export."""


class LocalFsDriver(FsDriver):
    """POSIX / local disk sandbox driver with atomic temp-file + fsync + replace."""

    def __init__(self, root_dir: str | Path) -> None:
        self.root = Path(root_dir).resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def _safe_path(self, rel_path: str) -> Path:
        clean = rel_path.strip().lstrip("/")
        if not clean or "/" in clean or "\\" in clean or clean in (".", ".."):
            raise ValueError(f"Invalid flat sandbox resource name: {rel_path!r}")
        p = (self.root / clean).resolve()
        if not p.is_relative_to(self.root):
            raise ValueError(f"Sandbox path traversal rejected: {rel_path!r}")
        return p

    def write_bytes(self, rel_path: str, data: bytes) -> None:
        target = self._safe_path(rel_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(prefix=".res-", dir=target.parent)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_name, target)
            dir_fd = os.open(target.parent, os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        finally:
            if os.path.exists(tmp_name):
                try:
                    os.unlink(tmp_name)
                except OSError:
                    pass

    def read_bytes(self, rel_path: str) -> bytes:
        target = self._safe_path(rel_path)
        if not target.is_file():
            raise FileNotFoundError(rel_path)
        return target.read_bytes()

    def exists(self, rel_path: str) -> bool:
        try:
            target = self._safe_path(rel_path)
        except ValueError:
            return False
        return target.is_file()

    def delete(self, rel_path: str) -> bool:
        target = self._safe_path(rel_path)
        try:
            target.unlink()
            return True
        except FileNotFoundError:
            return False

    def stat_size(self, rel_path: str) -> int:
        target = self._safe_path(rel_path)
        if not target.is_file():
            raise FileNotFoundError(rel_path)
        return target.stat().st_size

    def list_files(self) -> list[str]:
        if not self.root.is_dir():
            return []
        out: list[str] = []
        for p in sorted(self.root.iterdir()):
            if p.is_file() and not p.name.startswith("."):
                out.append(p.name)
        return out

    def resolve_local_path(self, rel_path: str) -> Path | None:
        try:
            target = self._safe_path(rel_path)
        except ValueError:
            return None
        return target if target.is_file() else None

    def copy_all_to(self, target_dir: str | Path) -> None:
        dest = Path(target_dir).resolve()
        dest.mkdir(parents=True, exist_ok=True)
        for name in self.list_files():
            shutil.copy2(self.root / name, dest / name)


class MemoryFsDriver(FsDriver):
    """In-memory sandbox filesystem driver for fast unit tests and virtual environments."""

    def __init__(self) -> None:
        self._blobs: dict[str, bytes] = {}

    def _check_name(self, rel_path: str) -> str:
        clean = rel_path.strip().lstrip("/")
        if not clean or "/" in clean or "\\" in clean or clean in (".", ".."):
            raise ValueError(f"Invalid flat sandbox resource name: {rel_path!r}")
        return clean

    def write_bytes(self, rel_path: str, data: bytes) -> None:
        name = self._check_name(rel_path)
        self._blobs[name] = bytes(data)

    def read_bytes(self, rel_path: str) -> bytes:
        name = self._check_name(rel_path)
        if name not in self._blobs:
            raise FileNotFoundError(rel_path)
        return self._blobs[name]

    def exists(self, rel_path: str) -> bool:
        try:
            name = self._check_name(rel_path)
        except ValueError:
            return False
        return name in self._blobs

    def delete(self, rel_path: str) -> bool:
        name = self._check_name(rel_path)
        return self._blobs.pop(name, None) is not None

    def stat_size(self, rel_path: str) -> int:
        name = self._check_name(rel_path)
        if name not in self._blobs:
            raise FileNotFoundError(rel_path)
        return len(self._blobs[name])

    def list_files(self) -> list[str]:
        return sorted(self._blobs.keys())

    def resolve_local_path(self, rel_path: str) -> Path | None:
        return None

    def copy_all_to(self, target_dir: str | Path) -> None:
        dest = Path(target_dir).resolve()
        dest.mkdir(parents=True, exist_ok=True)
        for name, data in self._blobs.items():
            (dest / name).write_bytes(data)


class PlatformShim:
    """Platform-agnostic utilities for UUIDs, timestamps, and cryptographic hashes.

    Allows deterministic injection during tests and clean porting across runtimes.
    """

    def new_id(self) -> str:
        """Generate a 32-char lowercase hex UUIDv4 (Joplin-compatible ID format)."""
        return uuid.uuid4().hex

    def now_iso(self) -> str:
        """Return current local ISO-8601 timestamp (seconds precision)."""
        return datetime.now().isoformat(timespec="seconds")

    def sha256_hex(self, data: bytes | str) -> str:
        """Compute full 64-char SHA-256 hex digest."""
        raw = data.encode("utf-8") if isinstance(data, str) else data
        return hashlib.sha256(raw).hexdigest()
