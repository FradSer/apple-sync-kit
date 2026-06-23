# Task 004: D1SyncClient Version Header and Version-Check Wiring (Green)

**depends-on**: task-004-version-header-test

## Description

Make `task-004-version-header-test` pass. Factor the three duplicated header-setting sites in `D1SyncClient` (`:86`, `:127`, `:169` pre-refactor) into one private `applyCommonHeaders(_:)` that adds `Authorization: Bearer <token>` and `X-AppleSyncKit-Version: <SyncAPIVersion.current>`. After each executor call, evaluate `SyncVersionPolicy.evaluate(client:serverHeader:)` against the response's `X-AppleSyncKit-Server-Version`; on `.warn`, emit exactly one stderr line per process, deduped by a `private var warnedMismatch = false` on the actor. The check must NEVER throw — a version skew must not break sync (requirement A6, best-practices "non-fatal and deduped").

This is the GREEN impl of the 004 version-header group; it runs after `task-004-version-header-test`.

## Execution Context

**Task Number**: 004 (impl) of 012
**Phase**: Core Features (version compatibility)
**Prerequisites**: `task-004-version-header-test` exists and fails.

## BDD Scenario

```gherkin
Scenario: Version warning is emitted at most once per process
  Given the Worker reports a different API version
  When I run several batched requests in one process
  Then the version warning is printed only once
```

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Modify: `Sources/AppleSyncKit/Network/D1SyncClient.swift`

## Steps

### Step 1: Add `applyCommonHeaders`
- Private method on `D1SyncClient` that takes an `inout HTTPClientRequest` (or returns headers) and sets `Authorization` + `X-AppleSyncKit-Version`. `Content-Type` stays where it is required (push/delete bodies). Replace the three duplicated `Authorization` additions with this single call.

Contract (signature only):
```swift
private func applyCommonHeaders(_ request: inout HTTPClientRequest)
```

### Step 2: Wire the version check
- Add `private var warnedMismatch = false`.
- After each executor `execute` returns, call `SyncVersionPolicy.evaluate(client: SyncAPIVersion.current, serverHeader: response.serverVersionHeader)`. On `.warn(message)` and `warnedMismatch == false`, emit one stderr line via the warning sink (default `writeStderr`) and set `warnedMismatch = true`. On `.ok`/`.unknown`, do nothing. Never throw from this path.

### Step 3: Verify (Green)
- `swift test --filter D1SyncClientHeadersTests` passes.
- Full suite passes (existing tests unaffected; the new header is additive).

## Verification Commands

```bash
swift test --filter D1SyncClientHeadersTests
swift test
swift format lint --strict --recursive Sources
```

## Success Criteria

- All three header sites go through `applyCommonHeaders`; no duplicated `Authorization`-add lines remain.
- Every push/pull/delete request carries both headers.
- Version mismatch warns exactly once per `D1SyncClient` instance lifetime and never throws.
- Missing/empty server header → `.unknown`, no warning, no crash.
- `swift format lint --strict` clean.
