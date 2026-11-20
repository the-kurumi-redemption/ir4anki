"""SQLite schema and versioned migrations for ir4anki Joplin-mode storage engine.

Single Source of Truth (`data.db`) covering:
- `notebooks`: Hierarchical folder tree (UUID, parent_id, pos, soft delete)
- `notes`: Markdown notes & metadata + reading queue status (`in_list`, `pos`, `body_sha`, `needs_resync`)
- `note_revisions`: Automatic historical snapshots on content/title changes for time-travel rollback
- `resources` & `note_resources`: Flat media sandbox (`media/<id>.<ext>`) with `(:/<id>)` link tracking
- `segments`: Progressive reading bookmark tree bound to `note_id` (decoupled from physical file paths)
- `segment_cards`: Anki note provenance (`note_id`, `seg_id`, `anki_note_id`)
- `note_orphans`: Drift-parked segment states for recovery on reseed
- `reading_round` & `storage_meta`: Active round state and system metadata
- `notes_fts`: FTS5 trigram full-text search index synchronized via SQLite triggers
"""
from __future__ import annotations

from .drivers import DatabaseDriver

SCHEMA_VERSION = 1

SCHEMA_V1_SQL = """
-- System & schema metadata
CREATE TABLE IF NOT EXISTS storage_meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);

-- Hierarchical notebooks (replaces physical folders)
CREATE TABLE IF NOT EXISTS notebooks (
    id          TEXT PRIMARY KEY,
    parent_id   TEXT REFERENCES notebooks(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    pos         INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL,
    deleted_at  TEXT DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS idx_notebooks_parent ON notebooks(parent_id, pos);
CREATE INDEX IF NOT EXISTS idx_notebooks_deleted ON notebooks(deleted_at);

-- Notes content, metadata, and reading-list membership (replaces .md files + rfiles)
CREATE TABLE IF NOT EXISTS notes (
    id            TEXT PRIMARY KEY,
    notebook_id   TEXT REFERENCES notebooks(id) ON DELETE SET NULL,
    title         TEXT NOT NULL,
    body          TEXT NOT NULL DEFAULT '',
    body_sha      TEXT NOT NULL DEFAULT '',
    in_list       INTEGER NOT NULL DEFAULT 0,
    list_pos      INTEGER NOT NULL DEFAULT 0,
    added_at      TEXT DEFAULT NULL,
    needs_resync  INTEGER NOT NULL DEFAULT 0,
    legacy_path   TEXT DEFAULT NULL,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL,
    deleted_at    TEXT DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS idx_notes_notebook ON notes(notebook_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_notes_list ON notes(in_list, list_pos) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_notes_legacy_path ON notes(legacy_path);
CREATE INDEX IF NOT EXISTS idx_notes_deleted ON notes(deleted_at);

-- Historical revisions for safe rollback / time-travel
CREATE TABLE IF NOT EXISTS note_revisions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    body        TEXT NOT NULL,
    body_sha    TEXT NOT NULL,
    reason      TEXT NOT NULL DEFAULT 'edit',
    created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_note_revisions_note ON note_revisions(note_id, id DESC);

-- Multimedia resources stored in flat media/ sandbox
CREATE TABLE IF NOT EXISTS resources (
    id            TEXT PRIMARY KEY,
    filename      TEXT NOT NULL,
    ext           TEXT NOT NULL,
    mime_type     TEXT NOT NULL,
    file_size     INTEGER NOT NULL,
    sha256        TEXT NOT NULL,
    legacy_name   TEXT DEFAULT NULL,
    created_at    TEXT NOT NULL,
    deleted_at    TEXT DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS idx_resources_sha256 ON resources(sha256);
CREATE INDEX IF NOT EXISTS idx_resources_legacy_name ON resources(legacy_name);

-- Many-to-many link table tracking which notes reference which resources (:/<resource_id>)
CREATE TABLE IF NOT EXISTS note_resources (
    note_id      TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    resource_id  TEXT NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
    PRIMARY KEY (note_id, resource_id)
);
CREATE INDEX IF NOT EXISTS idx_note_resources_res ON note_resources(resource_id);

-- Progressive reading segments (bound to immutable note_id instead of path)
CREATE TABLE IF NOT EXISTS segments (
    note_id       TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    seg_id        INTEGER NOT NULL,
    start_line    INTEGER NOT NULL,
    end_line      INTEGER NOT NULL,
    fingerprint   TEXT NOT NULL DEFAULT '',
    first_line    TEXT NOT NULL DEFAULT '',
    title         TEXT NOT NULL DEFAULT '',
    heading_path  TEXT NOT NULL DEFAULT '[]',
    status        TEXT NOT NULL DEFAULT 'todo',
    parent_seg_id INTEGER DEFAULT NULL,
    stale         INTEGER NOT NULL DEFAULT 0,
    updated_at    TEXT,
    PRIMARY KEY (note_id, seg_id)
);
CREATE INDEX IF NOT EXISTS idx_segments_parent ON segments(note_id, parent_seg_id);
CREATE INDEX IF NOT EXISTS idx_segments_order ON segments(note_id, start_line, seg_id);

-- Anki card provenance linked to segments
CREATE TABLE IF NOT EXISTS segment_cards (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id      TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    seg_id       INTEGER NOT NULL,
    anki_note_id INTEGER NOT NULL,
    FOREIGN KEY (note_id, seg_id) REFERENCES segments(note_id, seg_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_segment_cards_seg ON segment_cards(note_id, seg_id);
CREATE INDEX IF NOT EXISTS idx_segment_cards_anki ON segment_cards(anki_note_id);

-- Orphaned segment states parked on external drift
CREATE TABLE IF NOT EXISTS note_orphans (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id    TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    chunk_key  TEXT NOT NULL,
    data       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_note_orphans_note ON note_orphans(note_id);

-- Ephemeral reading round state (single row id=1)
CREATE TABLE IF NOT EXISTS reading_round (
    id   INTEGER PRIMARY KEY CHECK (id = 1),
    data TEXT
);

-- Atomic file/notebook operation log (replaces file_relocation.py journal)
CREATE TABLE IF NOT EXISTS file_operations (
    operation_id  TEXT PRIMARY KEY,
    request_id    TEXT UNIQUE,
    action        TEXT NOT NULL,
    old_path      TEXT NOT NULL,
    new_path      TEXT NOT NULL,
    is_dir        INTEGER NOT NULL DEFAULT 0,
    target_id     TEXT,
    undone        INTEGER NOT NULL DEFAULT 0,
    request_json  TEXT,
    created_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_file_operations_req ON file_operations(request_id);

-- Stand-off AI highlight & comment annotations layer (zero pollution to notes.body)
CREATE TABLE IF NOT EXISTS ai_annotations (
    id            TEXT PRIMARY KEY,
    note_id       TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    layer_name    TEXT NOT NULL DEFAULT 'default',
    quote_exact   TEXT NOT NULL,
    quote_prefix  TEXT NOT NULL DEFAULT '',
    quote_suffix  TEXT NOT NULL DEFAULT '',
    comment       TEXT NOT NULL DEFAULT '',
    line_hint     INTEGER NOT NULL DEFAULT 1,
    status        TEXT NOT NULL DEFAULT 'active',
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ai_annotations_note ON ai_annotations(note_id, status, line_hint);
CREATE INDEX IF NOT EXISTS idx_ai_annotations_layer ON ai_annotations(note_id, layer_name);

-- Read-only compatibility views for legacy path-based queries
CREATE VIEW IF NOT EXISTS rfiles AS
SELECT COALESCE(legacy_path, title) AS path, in_list, list_pos AS pos, added_at, body_sha AS file_sha, needs_resync
FROM notes WHERE deleted_at IS NULL;

CREATE VIEW IF NOT EXISTS rcards AS
SELECT COALESCE(n.legacy_path, n.title) AS path, sc.seg_id AS seg_id, sc.anki_note_id AS note_id
FROM segment_cards sc JOIN notes n ON n.id = sc.note_id WHERE n.deleted_at IS NULL;

CREATE VIEW IF NOT EXISTS rorphans AS
SELECT COALESCE(n.legacy_path, n.title) AS path, o.chunk_key AS chunk_key, o.data AS data
FROM note_orphans o JOIN notes n ON n.id = o.note_id WHERE n.deleted_at IS NULL;

CREATE VIEW IF NOT EXISTS rround AS
SELECT id, data FROM reading_round;
"""

FTS5_TRIGRAM_SQL = """
CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
    note_id UNINDEXED,
    title,
    body,
    tokenize='trigram'
);

CREATE TRIGGER IF NOT EXISTS trg_notes_fts_ai AFTER INSERT ON notes
WHEN new.deleted_at IS NULL
BEGIN
    INSERT INTO notes_fts(rowid, note_id, title, body)
    VALUES (new.rowid, new.id, new.title, new.body);
END;

CREATE TRIGGER IF NOT EXISTS trg_notes_fts_ad AFTER DELETE ON notes
BEGIN
    DELETE FROM notes_fts WHERE rowid = old.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_notes_fts_au AFTER UPDATE OF title, body, deleted_at ON notes
BEGIN
    DELETE FROM notes_fts WHERE rowid = old.rowid;
    INSERT INTO notes_fts(rowid, note_id, title, body)
    SELECT new.rowid, new.id, new.title, new.body
    WHERE new.deleted_at IS NULL;
END;
"""


def ensure_schema(driver: DatabaseDriver) -> int:
    """Initialize or migrate database schema to SCHEMA_VERSION.

    Returns the active schema version.
    """
    driver.executescript(SCHEMA_V1_SQL)
    try:
        driver.executescript(FTS5_TRIGRAM_SQL)
        fts_enabled = "1"
    except Exception:
        # Fallback if SQLite build lacks FTS5 trigram tokenizer; DAO search
        # seamlessly falls back to LIKE queries when fts_enabled != '1'.
        fts_enabled = "0"

    with driver.transaction():
        driver.execute(
            "INSERT INTO storage_meta(key, value) VALUES('schema_version', ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (str(SCHEMA_VERSION),),
        )
        driver.execute(
            "INSERT INTO storage_meta(key, value) VALUES('fts_enabled', ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (fts_enabled,),
        )
    return SCHEMA_VERSION
