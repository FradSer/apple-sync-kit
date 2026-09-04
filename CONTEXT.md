# Domain Model: AppleSyncKit

`AppleSyncKit` is an entity-agnostic synchronization framework for personal data across macOS and Linux clients with a Cloudflare D1 backend.

## Core Domain Concepts

### Entities & Records
- **Record**: A concrete data payload (e.g. note, reminder, calendar event) owned by the consumer application. The kit treats records as generic `Codable & Sendable` blobs.
- **Local ID vs Remote ID**: Local identifiers assigned by client platforms (e.g. CoreData URIs on macOS, integer/UUID strings in SQLite on Linux) mapped bi-directionally to persistent remote identifiers in D1.
- **Entity Profile / Descriptor**: Metadata and keypaths defining an entity type, its identity extractor, volatile field masks, and persistence mappings.

### Synchronization
- **Sync Coordinator**: The deep orchestrator managing synchronization runs. Encapsulates concurrency locks, state checkpointing, and push/pull pipeline execution. Exposes:
  - `sync(source:)`: Complete bidirectional lifecycle (lock -> push -> pull -> checkpoint -> unlock -> summary).
  - `push(source:)`: Targeted push-only execution for CLI diagnostics/flags.
  - `pull(source:)`: Targeted pull-only execution for CLI diagnostics/flags.
- **Local Sync Source (Seam)**: A unified, cohesive bidirectional adapter protocol over client storage mechanisms. Encapsulates:

  1. Local change detection (dirty items and deletion candidates).
  2. Applying remote upserts and deletes into local storage.
  3. Acknowledging successfully synced local modifications (e.g. clearing local-only flags).
  - **Snapshot Sync Source**: Adapter for EventKit/macOS comparing current record snapshots against previous state hashes.
  - **Flagged Sync Source**: Adapter for SQLite/Linux leveraging local modification flags (`is_local_only`) and tombstone rows (`deleted = 1`).

- **Sync Engine**: The core bidirectional synchronization pipeline implementing deterministic last-write-wins (LWW) conflict resolution based on ISO8601 timestamps.
### Persistence & Storage
- **Sync State Journal**: Cohesive persistence unit managing unified synchronization state in a single atomic file (`sync-state.json`), completely replacing the former three separate files (`state.json`, `id-mapping.json`, `cursors.json`). Enforces crash invariance via single atomic file rename.


### Backend Wire
- **D1 Sync Client**: Actor-based HTTP client communicating with Cloudflare Workers D1 endpoint.
- **Pull Cursor**: Composite monotonic sequence integer and tiebreaker ID `(seq, id)` tracking remote synchronization progress without missed writes.
