# Task 003: SyncVersionPolicy Implementation (Green)

**depends-on**: task-003-version-policy-test

## Description

Implement the pure `SyncVersionPolicy` enum so the matrix test from `task-003-version-policy-test` passes. Mirror `SyncCursorPolicy` (`Models/SyncTimestamp.swift:35`): a terse, stateless policy enum with a single static function and no side effects. The policy only compares and classifies — it never writes to stderr (that wiring lives in `D1SyncClient`, task 004 impl).

This is the GREEN impl of the 003 version-policy group; it runs after `task-003-version-policy-test`.

## Execution Context

**Task Number**: 003 (impl) of 012
**Phase**: Core Features (version compatibility)
**Prerequisites**: `task-003-version-policy-test` exists and fails.

## BDD Scenario

```gherkin
Scenario: Worker reports a different API version than the client
  Given the Worker reports an API version different from the client's
  When I run a sync
  Then a single non-fatal warning is surfaced to the user
  And the sync still proceeds
```

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Create: `Sources/AppleSyncKit/Models/SyncVersionPolicy.swift`

## Steps

### Step 1: Implement `SyncVersionPolicy`
- Define the contract exactly as the architecture specifies:

```swift
public enum SyncVersionPolicy {
  public enum Outcome: Sendable, Equatable { case ok, warn(String), unknown }
  public static func evaluate(client: String, serverHeader: String?) -> Outcome
}
```

- Behavior: `nil` or empty `serverHeader` → `.unknown`; `serverHeader == client` → `.ok`; otherwise `.warn(message)` where `message` is a non-fatal, body-free string naming both versions and advising an update.
- Keep it pure — no `writeStderr`, no actor, no state.

### Step 2: Verify (Green)
- `swift test --filter SyncVersionPolicyTests` passes.
- Run the full suite to confirm no regression.

## Verification Commands

```bash
swift test --filter SyncVersionPolicyTests
swift test
swift format lint --strict --recursive Sources
```

## Success Criteria

- The paired test passes.
- `Outcome` is `Sendable, Equatable`.
- No side effects in `evaluate`; the `.warn` message contains no token/body.
- `swift format lint --strict` clean.
