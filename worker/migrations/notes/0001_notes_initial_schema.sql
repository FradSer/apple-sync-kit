-- Migration 0001: initial schema
-- Applied tracking is handled by Wrangler's d1_migrations table.

CREATE TABLE IF NOT EXISTS notes (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL,
    last_modified TEXT NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    source_device TEXT
);

CREATE TABLE IF NOT EXISTS note_folders (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL,
    last_modified TEXT NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    source_device TEXT
);

CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes (updated_at, id);
CREATE INDEX IF NOT EXISTS idx_note_folders_updated ON note_folders (updated_at, id);
