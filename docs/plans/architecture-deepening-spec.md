# Specification: SyncCoordinator & Unified Architecture Deepening

## Problem Statement

As a developer maintaining or consuming `AppleSyncKit` (e.g. in `note` or `event` CLI applications):
- The sync engine interface is extremely shallow and cumbersome, requiring 13 to 16 separate parameters and complex callback closures per entity type.
- The push synchronization pipeline is split into two near-identical, divergent routines (`pushSnapshot` for macOS/EventKit and `pushLocalOnly` for Linux/SQLite), duplicating approximately 70% of core synchronization logic and creating maintenance fragility.
- Sync state persistence is fragmented across three separate on-disk JSON files (`state.json`, `id-mapping.json`, `cursors.json`), risking data inconsistency upon crashes or mid-page interruptions.

## Solution

Transform `AppleSyncKit` into a deep, resilient system by introducing:
1. **LocalSyncSource Adapter Seam**: A unified, bidirectional storage adapter abstraction replacing the split snapshot vs. local-only push routines with a single cohesive push/pull sync pipeline.
2. **SyncCoordinator**: A deep coordination module that encapsulates file locking, checkpoint commit transactions, and engine execution, providing clean `sync()`, `push()`, and `pull()` APIs.
3. **SyncStateJournal**: A consolidated, single-file persistence unit (`sync-state.json`) that writes all sync state atomically in lockstep.

## User Stories

1. As a CLI developer, I want to execute a bidirectional sync by providing a single `LocalSyncSource` to `SyncCoordinator`, so that I do not need to wire 16 distinct closures and key paths.
2. As a CLI developer, I want `SyncCoordinator` to manage file locking (`flock`) automatically during sync runs, so that concurrent executions are safely blocked with clear error reporting.
3. As a CLI developer, I want to invoke `--push-only` or `--pull-only` on `SyncCoordinator` with the same storage adapter, so that I can provide targeted diagnostic commands without duplicating orchestration code.
4. As a macOS client developer, I want a `SnapshotSyncSource` that computes entity state diffs and soft-deletes via snapshot hashes, so that EventKit data syncs correctly without manual flag tracking.
5. As a Linux client developer, I want a `FlaggedSyncSource` that pushes `is_local_only = 1` rows and clears flags upon sync confirmation, so that SQLite data syncs reliably without content diffing overhead.
6. As a sync engine maintainer, I want a single unified `push` implementation, so that enhancements, bug fixes, or optimizations to the push pipeline automatically apply to both macOS and Linux.
7. As a sync engine maintainer, I want state persistence, ID mappings, and pull cursors committed in a single atomic file write, so that mid-sync failures never leave mappings disconnected from cursors.
8. As a test author, I want to test the full sync coordinator against a mock or in-memory `LocalSyncSource`, so that tests verify end-to-end sync behavior at the highest seam without filesystem or network mocks.

## Scenarios

### Scenario 1: Successful Bidirectional Sync via Coordinator
```gherkin
Feature: Sync Coordinator Orchestration

  Scenario: Clean bidirectional sync run
    Given an initialized SyncCoordinator with valid configuration
    And a LocalSyncSource with 2 local modified records and 0 remote changes pending
    When the consumer executes coordinator.sync(source: source)
    Then the file lock is acquired
    And both local records are pushed to the remote service
    And local change acknowledgements are committed
    And pull changes are queried and applied to the source
    And sync state is atomically committed to sync-state.json
    And the file lock is released
    And a SyncSummary indicating 2 synced items is returned
```

### Scenario 2: Push-Only Mode Execution
```gherkin
Feature: Targeted Push Pipeline

  Scenario: Selective push execution for CLI flag
    Given an initialized SyncCoordinator with a LocalSyncSource containing 1 dirty record
    When the consumer executes coordinator.push(source: source)
    Then the dirty record is pushed to the remote backend
    And the local source confirms receipt of the pushed ID
    And no pull requests are made to the remote backend
    And a PushResult indicating 1 synced item is returned
```

### Scenario 3: Atomic Crash Resilience in State Journal
```gherkin
Feature: State Journal Atomicity

  Scenario: Interrupted sync run commits atomically
    Given an active SyncStateJournal with initial state
    When new ID mappings, entity states, and pull cursors are updated in memory
    And journal.commitCheckpoint() is executed
    Then the updated state is written to a temporary file with mode 0o600
    And atomic rename replaces sync-state.json in a single filesystem operation
    And all three sub-states remain strictly consistent
```

### Scenario 4: Concurrent Execution Prevention
```gherkin
Feature: Sync Lock Concurrency Guard

  Scenario: Second sync process encounters an active lock
    Given a sync run is currently holding the sync lock file
    When another process attempts to invoke coordinator.sync()
    Then the coordinator aborts immediately
    And throws SyncError.alreadyRunning
    And no remote or local modifications are made
```

## Implementation Decisions

1. **Unified Storage Seam**: Define `protocol LocalSyncSource<Record>: Sendable`. The protocol defines:
   - Consistent local change discovery: `func changes(context:) async throws -> LocalSyncChanges<Record>`
   - Application of remote upserts: `func applyRemoteUpsert(_ record: Record, localId: String, remoteId: String, lastModified: String) async throws -> String?
   - Application of remote deletes: `func applyRemoteDelete(localId: String) async throws -> Void`
   - Post-push acknowledgement: `func acknowledgePushed(localIds: [String]) async throws -> Void`
2. **Standard Adapters**:
   - `SnapshotSyncSource`: Wraps in-memory snapshots, computing dirty items and candidate removals via `SyncEntityState`.
   - `FlaggedSyncSource`: Wraps `SQLiteSyncStore`, querying `is_local_only = 1` and `deleted = 1` rows.
3. **Consolidated State Persistence**: Replace `state.json`, `id-mapping.json`, and `cursors.json` with a single unified `sync-state.json` file handled by `SyncStateJournal`. In alignment with project guidelines, no legacy fallback loaders are maintained.
4. **Deep SyncCoordinator**: Provide a Sendable struct `SyncCoordinator` initialized with `SyncConfig` and `ConfigStore`. It manages the acquisition and release of `flock`, executes the unified push and pull pipelines, and commits state updates atomically through `SyncStateJournal`.
5. **Preserving Wire Protocol Compatibility**: The HTTP interactions with the Cloudflare D1 Worker (`/api/v1/:entity/push`, `/api/v1/:entity/pull`, etc.) and the batch size constraints (`MAX_BATCH_SIZE = 500`) remain unchanged.

## Testing Decisions

- **Test Surface**: Test external behavior at the highest seam (`SyncCoordinator` and `LocalSyncSource`).
- **Memory Source Test Harness**: Create an in-memory test implementation of `LocalSyncSource` to verify end-to-end sync, push, pull, conflict resolution, and deletion without touching disk or databases.
- **State Journal Verification**: Test atomic writing, corrupt-data rejection, and round-trip fidelity of `SyncStateJournal`.
- **Concurrency & Error Verification**: Verify `SyncError.alreadyRunning` when lock contention occurs.

## Out of Scope

- Changes to Cloudflare D1 Worker schema or worker API endpoints.
- Cloud auth/token-refresh features from Dual-Mode Sync plan (remains cleanly decoupled).
- Backward compatibility migration scripts for obsolete multi-file `state.json`.

## Further Notes

- Complies with ADR-0001 (Consolidate Sync Persistence into a Single Sync State Journal).
- Uses domain vocabulary established in `CONTEXT.md`.
