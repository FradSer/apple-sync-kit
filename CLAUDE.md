# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`AppleSyncKit` is a generic, **entity-agnostic** Swift library — the shared core behind several personal sync CLIs (e.g. note-sync, reminder-sync). It implements one bidirectional, last-write-wins sync algorithm against a Cloudflare D1 sync Worker, plus the supporting crypto, persistence, SQLite, and HTTP pieces.

The kit owns **no** entity types and **no** on-disk JSON schema. Consuming projects pass their own `Codable` record/state/cursor/mapping types in, addressed via `WritableKeyPath`s. Keep every API generic over the record type and take the entity name as a `String` — never bake a concrete entity (notes, reminders, …) into the kit.

## Commands

- Build: `swift build` (the first build resolves a large SwiftNIO/swift-crypto graph and is slow; later builds are fast)
- Test: `swift test` — single test: `swift test --filter EncryptionServiceTests/testEncryptDecryptRoundTrip`
- Format (write in place): `swift format --in-place --recursive Sources Tests`
- Lint: `swift format lint --strict --recursive Sources Tests`

Formatter/linter is Apple **swift-format**, driven by `.swift-format` (2-space indent, 100-col lines). It is the bundled `swift format` subcommand — there is no standalone `swift-format` binary, and this project does **not** use Biome or SwiftLint.

## Toolchain & concurrency

- swift-tools 6.2, **Swift 6 language mode (strict concurrency)**, platform macOS 14+.
- Every type crossing a concurrency boundary must be `Sendable`; stateful services are `actor`s (`EncryptionService`, `D1SyncClient`).
- `SQLite/Connection+Sendable.swift` declares `extension Connection: @retroactive @unchecked Sendable`. This is **intentional and must live only here** — consuming projects import it and must not redeclare it. `swift format lint` flags it as `AvoidRetroactiveConformances`; that warning is expected — do not "fix" it.

## Architecture & invariants

Dependencies point inward; the kit has no composition root (wiring is the consuming CLI's job).

- **`Engine/SyncEngine.swift`** — a stateless `enum` of static generic functions: the one shared algorithm. Two push strategies, `pushSnapshot` (EventKit/macOS, diff against recorded state) and `pushLocalOnly` (SQLite/Linux `is_local_only` flag); one cursor-based `pull`. Conflicts resolve last-write-wins by `lastModified`. Invariant: synced state is persisted **before** any delete RPC fires, so a failed delete can never lose a recorded push — preserve this ordering.
- **`Network/D1SyncClient.swift`** (`actor`) — HTTP client for the D1 Worker. `maxBatchSize = 500` **must match `MAX_BATCH_SIZE` in the Cloudflare Worker** (separate repo); changing one without the other breaks batching.
- **`Persistence/ConfigStore.swift`** — JSON state under `~/.config/<namespace>/`, mode 0o600 via atomic rename, guarded by an exclusive `flock`. Use `loadJSONStrict` for state/id-mapping (throws on corruption — never silently reset) and `loadJSON` for cursors (rebuildable — warns and returns default).
- **`Crypto/EncryptionService.swift`** (`actor`) — AES-GCM over any `Codable` payload, binding `recordId|modifiedDate` as AAD.
- **`SQLite/SQLiteSyncStore.swift`** — generic JSON-blob row helpers; each entity is one table with `data`/`deleted`/`is_local_only` columns.
- **`Daemon/LaunchAgentManager.swift`** (macOS-only, `#if os(macOS)`) — renders/installs/inspects per-user launchd agents for background sync. Entity-agnostic: the consumer supplies the label, program arguments, and environment (encryption key included — launchd jobs don't inherit shell env). Lock contention surfaces as `SyncError.alreadyRunning` so a daemon-triggered run can skip quietly.
- Public value types live in `Models/`; `DTO/` holds internal wire types (`RawJSON`/`JSONValue` preserve server bytes without an `AnyCodable` dependency).

## Configuration (consumer-facing)

Config resolves env-first, then `~/.config/<namespace>/config.json`. Env keys are prefixed per consuming project: `<PREFIX>_SYNC_API_URL`, `<PREFIX>_SYNC_API_TOKEN`, `<PREFIX>_SYNC_DEVICE_ID`. The API URL must be HTTPS. The encryption key is a separate base64 32-byte env var (`openssl rand -base64 32`), exported on every device.

## Tests

XCTest (not swift-testing), in `Tests/AppleSyncKitTests/`. Async tests are `async throws` and `await` the actor calls.
