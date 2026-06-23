# AppleSyncKit ![](https://img.shields.io/badge/Swift-6-f05138) ![](https://img.shields.io/badge/macOS-14%2B-blue)

[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen)](https://swift.org/package-manager/)

**English** | [简体中文](README.zh-CN.md)

A generic, entity-agnostic Swift library for bidirectional sync against a Cloudflare D1 Worker. It implements a last-write-wins sync algorithm with AES-GCM encryption, batched HTTP transport, and local SQLite persistence — designed to be embedded by consuming CLIs that bring their own record types.

## Architecture

The library has no built-in entity types or JSON schema. Consuming projects pass their own `Codable` types via `WritableKeyPath`s, and address entities by name string. Dependencies point inward; there is no composition root — wiring is the consuming CLI's job.

```
SyncEngine (stateless algorithm)
    ↓
D1SyncClient (HTTP transport, actor)
    ↑
ConfigStore (persistence)    EncryptionService (AES-GCM, actor)
    ↑
SQLiteSyncStore (local DB)
```

### Sync Strategies

The engine offers two push strategies and one pull:

- **`pushSnapshot`** — For EventKit/macOS. Diffs the current state against a recorded snapshot, pushes changed items, then soft-deletes remote IDs no longer present locally. State is persisted before any delete RPC fires, so a failed delete never loses a recorded push.
- **`pushLocalOnly`** — For SQLite/Linux. Pushes items flagged `is_local_only`, clears the flag, then handles deletions.
- **`pull`** — Cursor-based incremental pull with last-write-wins conflict resolution. Project-supplied closures handle upsert and delete.

## Modules

| Module | Purpose |
|---|---|
| **Engine** | Stateless sync algorithm (`pushSnapshot`, `pushLocalOnly`, `pull`) |
| **Network** | `actor`-based HTTP client for the D1 Worker; batch size 500 (must match Worker's `MAX_BATCH_SIZE`) |
| **Crypto** | AES-GCM encryption of `Codable` payloads with `recordId\|modifiedDate` AAD binding |
| **Models** | Value types: `SyncEntityState`, `SyncResults`, `SyncMapping`, `SyncTimestamp`, `DateFormatting` |
| **DTO** | Internal wire types (`RawJSON`, `JSONValue` preserve server bytes without `AnyCodable`) |
| **Errors** | `SyncError` enum; `SyncNotFound` protocol for cross-module "not-found" recognition |
| **Persistence** | JSON state under `~/.config/<namespace>/`, exclusive `flock`, atomic 0o600 writes |
| **SQLite** | Generic row helpers for local sync; `Connection: @unchecked Sendable` extension |

### Consumers

| CLI | Entities | Repository |
|---|---|---|
| [note](https://github.com/FradSer/note) | Apple Notes (notes, folders) | `git@github.com:FradSer/note.git` |
| [event](https://github.com/FradSer/event) | Apple Reminders & Calendar (reminders, calendar events, lists) | `git@github.com:FradSer/event.git` |

Both CLIs consume the Swift library via `AppleSyncKit` and deploy the shared
[canonical Worker](worker/) against their own D1 database. The Worker is
entity-agnostic — the table set is driven by the `ENTITIES` wrangler var.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/FradSer/apple-sync-kit.git", from: "0.1.0"),
],
targets: [
  .target(
    name: "YourCLI",
    dependencies: [.product(name: "AppleSyncKit", package: "apple-sync-kit")]
  ),
]
```

## Configuration

Config resolves env-first, then `~/.config/<namespace>/config.json`. Environment keys are prefixed per consuming project:

| Env Var | Purpose |
|---|---|
| `<PREFIX>_SYNC_API_URL` | D1 Worker URL (must be HTTPS) |
| `<PREFIX>_SYNC_API_TOKEN` | Bearer token for the Worker |
| `<PREFIX>_SYNC_DEVICE_ID` | Unique device identifier |
| `<PREFIX>_SYNC_ENCRYPTION_KEY` | Base64 32-byte key (`openssl rand -base64 32`) |

Export the encryption key on every device that participates in sync.

## Development

**Requirements:** Swift 6.2+, macOS 14+

```bash
# Build
swift build

# Test
swift test

# Single test
swift test --filter EncryptionServiceTests/testEncryptDecryptRoundTrip

# Format (in place)
swift format --in-place --recursive Sources Tests

# Lint
swift format lint --strict --recursive Sources Tests
```

The formatter is Apple `swift-format` (the bundled `swift format` subcommand), configured via `.swift-format` (2-space indent, 100-column lines). This is not SwiftLint.

### Concurrency Model

Swift 6 strict concurrency. Every type crossing a concurrency boundary is `Sendable`. Stateful services (`EncryptionService`, `D1SyncClient`) are `actor`s. The `Connection: @retroactive @unchecked Sendable` extension in `SQLite/Connection+Sendable.swift` is intentional and must live only there — consuming projects import it and must not redeclare it.

## License

MIT
