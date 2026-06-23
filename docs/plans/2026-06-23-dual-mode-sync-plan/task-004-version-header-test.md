# Task 004: D1SyncClient Common Headers and Warn-Once Test (Red)

**depends-on**: task-002-executor-seam, task-003-version-policy-impl

## Description

Write failing XCTests that drive the `D1SyncClient` version-header integration via the injected `HTTPRequestExecutor` (task 002): every outbound request (push, pull, delete) must carry `Authorization: Bearer <token>` AND `X-AppleSyncKit-Version: <SyncAPIVersion.current>`; on a server-version mismatch exactly one stderr warning is emitted across multiple requests in one process; a missing server-version header produces no warning and no crash; matching versions produce no warning.

Tests use a stub `HTTPRequestExecutor` that records every `HTTPClientRequest` it receives and returns canned `ExecutedResponse` values (including a chosen `X-AppleSyncKit-Server-Version`). To assert the single-warning behavior, inject a capturable stderr sink (a closure/seam) rather than reading real process stderr — extend the warning path to be observable in tests if needed, keeping production default = `writeStderr`.

This is the RED test of the 004 version-header group.

## Execution Context

**Task Number**: 004 (test) of 012
**Phase**: Core Features (version compatibility)
**Prerequisites**: Tasks 002 (seam) and 003 impl (policy) complete.

## BDD Scenario

```gherkin
Scenario: Version warning is emitted at most once per process
  Given the Worker reports a different API version
  When I run several batched requests in one process
  Then the version warning is printed only once

Scenario: Worker omits the API version header
  Given the Worker response carries no API version header
  When I run a sync
  Then the client treats the version as unknown and does not crash
  And no warning is emitted

Scenario: Client and Worker API versions match
  Given the Worker reports its API version via the response header
  And it equals the client's version
  When I run a sync
  Then no version warning is emitted
```

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Create: `Tests/AppleSyncKitTests/D1SyncClientHeadersTests.swift`
- Create (test helper): a recording stub conforming to `HTTPRequestExecutor` (in the same test file or a shared `Tests/AppleSyncKitTests/Support/` file, reused by tasks 005, 006, 007, 008)

## Steps

### Step 1: Verify Scenario
- Confirm the three scenarios above exist in `bdd-specs.md`.

### Step 2: Implement Test (Red)
- Build a `RecordingExecutor: HTTPRequestExecutor` capturing each request's URL, method, and headers, and returning a configurable `(status, serverVersionHeader, body)`.
- Construct `D1SyncClient` with the recording executor and a known `SyncConfig`.
- Assertions:
  - After a `push`, `pull`, and `delete`, each recorded request has `Authorization == "Bearer <token>"` and `X-AppleSyncKit-Version == SyncAPIVersion.current`.
  - With `serverVersionHeader` set to a different value, running multiple requests yields exactly **one** captured warning line.
  - With `serverVersionHeader == nil`, zero warnings and no thrown error.
  - With `serverVersionHeader == SyncAPIVersion.current`, zero warnings.
  - A version mismatch never causes any sync call to throw (sync still proceeds).
- **Verification**: FAILS because `applyCommonHeaders`, the version header, and the warn-once wiring do not exist yet.

## Verification Commands

```bash
swift test --filter D1SyncClientHeadersTests
```

## Success Criteria

- Test compiles against the task-002 seam and fails (Red) prior to the 004 impl task.
- The stub executor is offline (no NIO server).
- The warning observation seam does not change production default behavior (still `writeStderr`).
