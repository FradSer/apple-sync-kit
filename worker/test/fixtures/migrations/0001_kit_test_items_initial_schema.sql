-- Test-only fixture migration for the apple-sync-kit Worker runtime.
-- This table is NOT business data; it exists solely so the kit's own tests can
-- exercise the entity-agnostic push/pull/delete/cursor flow against *some*
-- table without depending on any consumer's business schema (notes, events,
-- etc.). Consumer repos own their real migrations; the kit ships none.
CREATE TABLE IF NOT EXISTS kit_test_items (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL,
    last_modified TEXT NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    source_device TEXT
);

CREATE INDEX IF NOT EXISTS idx_kit_test_items_updated ON kit_test_items (updated_at, id);
