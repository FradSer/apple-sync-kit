-- Migration 0002: monotonic pull cursor
--
-- The pull cursor was keyed on `updated_at` (a wall-clock `datetime('now')`).
-- A wall clock can move backward: a manual D1 write, host clock skew, or a D1
-- Time-Travel restore can stamp rows with a time earlier than a cursor a device
-- already holds, permanently stranding that device (its `updated_at > cursor`
-- query then matches nothing). Replace the cursor key with a strictly increasing
-- per-table integer `seq` that the Worker bumps on every applied write, so a
-- stored cursor can never sit above a future write.

ALTER TABLE notes ADD COLUMN seq INTEGER NOT NULL DEFAULT 0;
ALTER TABLE note_folders ADD COLUMN seq INTEGER NOT NULL DEFAULT 0;

-- Backfill existing rows with distinct, increasing values in insertion order.
UPDATE notes SET seq = rowid;
UPDATE note_folders SET seq = rowid;

CREATE INDEX IF NOT EXISTS idx_notes_seq ON notes (seq, id);
CREATE INDEX IF NOT EXISTS idx_note_folders_seq ON note_folders (seq, id);
