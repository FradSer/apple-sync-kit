-- Migration 0002: monotonic pull cursor
--
-- The pull cursor was keyed on `updated_at` (a wall-clock `datetime('now')`).
-- A wall clock can move backward: a manual D1 write, host clock skew, or a D1
-- Time-Travel restore can stamp rows with a time earlier than a cursor a device
-- already holds, permanently stranding that device (its `updated_at > cursor`
-- query then matches nothing). Replace the cursor key with a strictly
-- increasing per-table integer `seq` that the Worker bumps on every applied
-- write, so a stored cursor can never sit above a future write.

ALTER TABLE reminders ADD COLUMN seq INTEGER NOT NULL DEFAULT 0;
ALTER TABLE calendar_events ADD COLUMN seq INTEGER NOT NULL DEFAULT 0;
ALTER TABLE reminder_lists ADD COLUMN seq INTEGER NOT NULL DEFAULT 0;

-- Backfill existing rows with distinct, increasing values in insertion order.
UPDATE reminders SET seq = rowid;
UPDATE calendar_events SET seq = rowid;
UPDATE reminder_lists SET seq = rowid;

CREATE INDEX IF NOT EXISTS idx_reminders_seq ON reminders (seq, id);
CREATE INDEX IF NOT EXISTS idx_calendar_events_seq ON calendar_events (seq, id);
CREATE INDEX IF NOT EXISTS idx_reminder_lists_seq ON reminder_lists (seq, id);
