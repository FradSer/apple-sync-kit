# Task 002: Foundation — HTTPRequestExecutor Seam and D1SyncClient Injection Refactor

**depends-on**: _(none)_

## Description

Introduce a small `Sendable` request-executor seam so HTTP requests built by `D1SyncClient` (and later `AuthClient`) can be asserted offline against canned `(status, headers, body)` fixtures, with no live NIO server in unit tests. Refactor `D1SyncClient` to route every `execute` call through an injected `HTTPRequestExecutor`, defaulting to a real `AsyncHTTPClient`-backed implementation so production behavior is unchanged.

This is a **behavior-preserving refactor**: no new headers, no new routes, no protocol change on the wire. It exists to make tasks 005, 007, 008, 009, 011 testable. Existing tests must pass unmodified (A10).

Per `best-practices.md` ("Tests follow the established injection seam"): keep the protocol minimal — one async method returning a capturable response value type. Do not leak NIO types that break `Sendable`.

## Execution Context

**Task Number**: 002 of 012
**Phase**: Foundation
**Prerequisites**: None.

## BDD Scenario

Enables the offline assertion underpinning the mode-agnostic guarantee:

```gherkin
Scenario Outline: Sync behaves identically for any token source
  Given a SyncConfig whose API token was obtained via <source>
  When I run push, pull, and delete
  Then the requests carry the same Authorization bearer header shape
  And the same /api/v1/<entity> routes are used
  And no request differs based on how the token was obtained
```

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Create: `Sources/AppleSyncKit/Network/HTTPRequestExecutor.swift`
- Modify: `Sources/AppleSyncKit/Network/D1SyncClient.swift` (init, the three `httpClient.execute(...)` call sites at `:88`, `:134`, `:173`, and `shutdown()`)

## Steps

### Step 1: Define the seam
- A `public protocol HTTPRequestExecutor: Sendable` with one async throwing method that takes the request and timeout and returns a small `Sendable` response value carrying at least: status code, a way to read response headers (specifically `X-AppleSyncKit-Server-Version`), and the collected body bytes (respecting the existing 1 MB / 10 MB ceilings supplied by the caller).
- Provide a default real implementation backed by `HTTPClient(eventLoopGroupProvider: .singleton)` plus a `shutdown()`.

Contract (signatures only):
```swift
public struct ExecutedResponse: Sendable {
  public let status: Int
  public let serverVersionHeader: String?
  public let body: Data
}

public protocol HTTPRequestExecutor: Sendable {
  func execute(_ request: HTTPClientRequest, bodyLimit: Int, timeout: TimeAmount) async throws -> ExecutedResponse
  func shutdown() async throws
}

public struct RealHTTPRequestExecutor: HTTPRequestExecutor { /* HTTPClient(.singleton) */ }
```

### Step 2: Inject into `D1SyncClient`
- Add a designated initializer taking an `HTTPRequestExecutor`; keep the existing `public init(config:)` as a convenience that supplies `RealHTTPRequestExecutor()`.
- Replace the three direct `httpClient.execute(...)` + `response.body.collect(...)` sequences with calls through the executor. Map the existing error branches (`SyncError.unknown("… failed (\(status)): \(body)")`) onto the new response value with identical messages and status/ceiling semantics.
- Route `shutdown()` to the executor.

### Step 3: Verify behavior preserved
- `swift build`; `swift test` — all existing `ConfigStoreTests`, `EncryptionServiceTests`, `SyncModelsTests` pass unchanged.

## Verification Commands

```bash
swift build
swift test
swift format lint --strict --recursive Sources
```

## Success Criteria

- `D1SyncClient` no longer references `HTTPClient` directly except through `RealHTTPRequestExecutor`.
- Existing test suite passes with zero modifications.
- The seam type and `ExecutedResponse` are `Sendable`; no `@unchecked`/`any`-cast escape hatch added.
- Wire behavior (routes, methods, headers, ceilings, error messages) is byte-identical to before this task.
