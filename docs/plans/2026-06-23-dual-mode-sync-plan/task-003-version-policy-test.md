# Task 003: SyncVersionPolicy Comparison Matrix Test (Red)

**depends-on**: _(none)_

## Description

Write the failing XCTest for a pure `SyncVersionPolicy.evaluate(client:serverHeader:)` comparison helper, mirroring how `SyncCursorPolicy` (`Models/SyncTimestamp.swift:35`) is a pure, stateless policy enum. The test asserts the full matrix: equal versions → `.ok`; different → `.warn(message)`; `nil`/empty server header → `.unknown`. This is the unit underpinning the API-version-compatibility BDD feature.

This is the RED test of the 003 version-policy group; the paired `task-003-version-policy-impl` runs after it.

## Execution Context

**Task Number**: 003 (test) of 012
**Phase**: Core Features (version compatibility)
**Prerequisites**: None — `evaluate` takes both versions as parameters and depends on no other kit type.

## BDD Scenario

```gherkin
Scenario: Client and Worker API versions match
  Given the Worker reports its API version via the response header
  And it equals the client's version
  When I run a sync
  Then no version warning is emitted

Scenario: Worker reports a different API version than the client
  Given the Worker reports an API version different from the client's
  When I run a sync
  Then a single non-fatal warning is surfaced to the user
  And the sync still proceeds

Scenario: Worker omits the API version header
  Given the Worker response carries no API version header
  When I run a sync
  Then the client treats the version as unknown and does not crash
  And no warning is emitted
```

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Create: `Tests/AppleSyncKitTests/SyncVersionPolicyTests.swift`

## Steps

### Step 1: Verify Scenario
- Confirm the three version scenarios above exist in `bdd-specs.md` under "API version compatibility".

### Step 2: Implement Test (Red)
- Add a `final class SyncVersionPolicyTests: XCTestCase` following the style of `ConfigStoreTests`.
- Cases:
  - `evaluate(client: "1", serverHeader: "1")` → `.ok`
  - `evaluate(client: "1", serverHeader: "2")` → `.warn(_)` (assert it is the `.warn` case; the message is non-empty and contains neither a token nor a body)
  - `evaluate(client: "1", serverHeader: nil)` → `.unknown`
  - `evaluate(client: "1", serverHeader: "")` → `.unknown` (empty header treated as absent — no crash)
- Because `Outcome` is `Equatable`, assert `.ok` / `.unknown` by equality and `.warn` by pattern match.
- **Verification**: test FAILS to compile/pass because `SyncVersionPolicy` does not yet exist.

## Verification Commands

```bash
swift test --filter SyncVersionPolicyTests
```

## Success Criteria

- The test file exists and references `SyncVersionPolicy.evaluate` and `SyncVersionPolicy.Outcome`.
- Running the filter fails (Red) prior to the 003 impl task.
- No network, no actor, no fixture — pure synchronous assertions.
