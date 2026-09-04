# Changelog

## [0.5.0] - 2026-09-04

### Added
- Deep `SyncCoordinator` orchestration with one lock and one HTTP client per multi-entity session
- Unified `LocalSyncSource` adapters for snapshot- and SQLite flag-based local stores
- Atomic single-file `SyncStateJournal` persistence in `sync-state.json`
- Typed delete results and accepted push ID acknowledgements

### Changed
- Replace the static `SyncEngine` and split state files with the coordinator, adapters, and consolidated journal
- Propagate local deletion timestamps through the Worker to enforce tombstone last-write-wins semantics
- Update the canonical Worker delete response to `deleted`, `already_absent`, or `rejected`

### Fixed
- Preserve deletion retry state after conflicts or local finalization failures
- Prevent stale upserts from resurrecting newer tombstones
- Detect remote deletions when known records disappear locally without explicit tombstone rows

## [0.4.1] - 2026-08-08

### Fixed
- Guard macOS-only tests with `#if os(macOS)` to unbreak Linux CI

## [0.1.0] - 2026-06-23

### Added
- Initial release of AppleSyncKit, the shared Apple sync infrastructure extracted from the `note` and `event` CLIs
- AES-GCM end-to-end encryption (`EncryptionService`, `EncryptedCarrier`)
- Generic Cloudflare D1 sync client (`D1SyncClient`) with batch push, cursor-paginated pull, and soft delete
- Generic bidirectional sync engine (`SyncEngine`) with snapshot and local-only push strategies and a shared pull loop
- `ConfigStore` for environment-precedence configuration and atomic 0600 state persistence
- SQLite local-store helpers (`SQLiteSyncStore`) and a `Connection: Sendable` conformance
- Sync models and DTOs: `SyncConfig`, `SyncEntityState`, `SyncTimestamp`, `SyncCursorPolicy`, `SyncMapping`

### Fixed
- `SyncEntityState` decodes legacy state files missing `dateRangeByRemoteId` (custom `init(from:)` defaulting absent fields)
- `D1SyncClient` percent-encodes `/` in record ids so slash-bearing ids (e.g. `x-coredata://…`) resolve the Worker's delete route instead of 404ing

[0.5.0]: https://github.com/FradSer/apple-sync-kit/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/FradSer/apple-sync-kit/compare/v0.4.0...v0.4.1
