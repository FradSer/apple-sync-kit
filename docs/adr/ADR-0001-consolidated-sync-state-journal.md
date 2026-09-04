# ADR-0001: Consolidate Sync Persistence into a Single Sync State Journal

## Status
Accepted

## Context
Previously, `AppleSyncKit` persisted state across three independent JSON files in `~/.config/<namespace>/`:
1. `state.json` (per-entity known IDs, timestamps, content snapshots, date ranges)
2. `id-mapping.json` (remote-to-local ID dictionary)
3. `cursors.json` (pull cursors for incremental sync)

During pull pagination or error recovery, `SyncEngine` had to interleave reads and writes across all three files. If an interruption occurred mid-sequence, partial writes could leave mappings out of sync with cursors and local states.

## Decision
Deprecate the tripartite file structure and replace it with a single, consolidated `sync-state.json` managed by `SyncStateJournal`.
In accordance with the project principle ("Do not preserve backward compatibility: remove obsolete paths instead of adding compatibility layers, fallbacks, or migrations"), old file paths will not have backward-compatibility fallback loaders. A clean unified format will be used.

## Consequences
### Positive
- Strict atomic updates via single-file atomic rename (0o600 via temp file).
- Invariant integrity: `idMapping`, `entityState`, and `cursor` are guaranteed to be committed in lockstep.
- Eliminates multi-file error recovery logic and file-path sprawl.

### Negative / Trade-offs
- Upgrading clients or local directories requires either regenerating local sync state or re-pulling from the remote D1 Worker.
