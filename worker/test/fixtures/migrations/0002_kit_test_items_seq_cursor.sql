-- Test-only fixture: the monotonic seq column + (seq, id) index that the
-- Worker's composite cursor pagination relies on (mirrors the pattern every
-- consumer's real 0002 migration follows). Not business data.
ALTER TABLE kit_test_items ADD COLUMN seq INTEGER NOT NULL DEFAULT 0;
UPDATE kit_test_items SET seq = rowid;
CREATE INDEX IF NOT EXISTS idx_kit_test_items_seq ON kit_test_items (seq, id);
