# Changelog

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
