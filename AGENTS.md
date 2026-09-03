# Repository Guidelines

`AppleSyncKit` is an entity-agnostic Swift package providing bidirectional, last-write-wins synchronization against a Cloudflare D1 Worker backend, shared across consumer CLIs (`note`, `event`).

## Project Structure & Module Organization

- **`Sources/AppleSyncKit/`**: Core Swift library.
  - `Engine/SyncEngine.swift`: Stateless generic synchronization algorithms (`pushSnapshot`, `pushLocalOnly`, `pull`).
  - `Network/D1SyncClient.swift`: Actor HTTP client communicating with Cloudflare D1 (`maxBatchSize = 500` aligned with Worker `MAX_BATCH_SIZE`).
  - `Persistence/ConfigStore.swift`: Thread-safe configuration and JSON state management (`~/.config/<namespace>/`, mode 0o600, `flock`).
  - `Crypto/EncryptionService.swift`: AES-GCM encryption with `recordId|modifiedDate` AAD binding.
  - `SQLite/`: Local SQLite row helpers and connection extensions.
  - `Daemon/LaunchAgentManager.swift`: macOS launchd background agent management (`#if os(macOS)`).
  - `Models/`, `DTO/`, `Errors/`: Public models, internal wire DTOs (`RawJSON`), and typed sync errors.
- **`Tests/AppleSyncKitTests/`**: XCTest test suites.
- **`worker/`**: Canonical Cloudflare D1 sync Worker implementation.
- *Note on tooling*: `@fradser/pi-kit` workspace runtime is absent in this repository.

## Build, Test & Development Commands

- **Build**: `swift build` (SwiftPM; initial build resolves SwiftNIO/swift-crypto).
- **Run all tests**: `swift test`
- **Run single test**: `swift test --filter EncryptionServiceTests/testEncryptDecryptRoundTrip`
- **Format code**: `swift format --in-place --recursive Sources Tests`
- **Lint code**: `swift format lint --strict --recursive Sources Tests`

Formatting is governed by `.swift-format` (2-space indent, 100-character line limit). Do not use Biome or SwiftLint for Swift code.

## Coding Style & Concurrency

- **Toolchain**: Swift 6.2 with strict concurrency (`SWIFT_DEFAULT_ACTOR_ISOLATION = complete`), macOS 14+ / Linux.
- Types crossing concurrency boundaries must conform to `Sendable`; stateful services must be `actor`s (`EncryptionService`, `D1SyncClient`).
- In `SQLite/Connection+Sendable.swift`, `extension Connection: @retroactive @unchecked Sendable` is intentional. The `AvoidRetroactiveConformances` lint warning is expected and must not be removed.
- Keep the library entity-agnostic: use generic records and dynamic keypaths (`WritableKeyPath`); do not hardcode consumer-specific domain types.
- Persist synced state before triggering delete RPCs to prevent losing pushes on network failure.

## Testing Guidelines

- Use XCTest in `Tests/AppleSyncKitTests/`. Async tests should be `async throws` awaiting actors.
- Platform-specific features (such as `LaunchAgentManager`) must be guarded with `#if os(macOS)` in test files so Linux CI passes.

## Commit & Pull Request Guidelines

- Commit messages follow Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `style:`, `refactor:`, `ci:`. Scopes like `(src)` may be used.
- Pull requests target `main` (active development branch is `develop`).
- CI validates code formatting (`swift format` producing zero diff), Linux tests under Swift 6.2 container, and macOS 14 tests. Tags matching `v*.*.*` or `*.*.*` trigger automated GitHub release generation.
