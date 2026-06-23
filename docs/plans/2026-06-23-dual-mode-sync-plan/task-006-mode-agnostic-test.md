# Task 006: Mode-Agnostic Identical-Request Guard (Test-only)

**depends-on**: task-002-executor-seam, task-004-version-header-impl

## Description

Lock the central invariant (requirements A3, A7): the sync wire path is byte-identical regardless of how the API token was obtained. Drive the Scenario Outline with all four token sources and assert the constructed push/pull/delete requests carry the same `Authorization` bearer shape, the same `/api/v1/<entity>` routes, and the same header set — differing only in the token string itself.

**Why test-only (no impl pair):** the sync path already ignores token origin (the token is just a string in `SyncConfig`); this guard proves that property and fails only if someone later special-cases a token source. (Intentional exception to test/impl pairing; see `_index.md` "Note on guard tests".)

## Execution Context

**Task Number**: 006 of 012
**Phase**: Refinement (regression guard)
**Prerequisites**: Tasks 002 (seam) and 004 impl (final header set) complete.

## BDD Scenario

```gherkin
Scenario Outline: Sync behaves identically for any token source
  Given a SyncConfig whose API token was obtained via <source>
  When I run push, pull, and delete
  Then the requests carry the same Authorization bearer header shape
  And the same /api/v1/<entity> routes are used
  And no request differs based on how the token was obtained

  Examples:
    | source                  |
    | static env var          |
    | static config.json      |
    | cloud register response |
    | cloud login response    |
```

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Create: `Tests/AppleSyncKitTests/ModeAgnosticSyncTests.swift`

## Steps

### Step 1: Verify Scenario
- Confirm the Scenario Outline exists under "Mode-agnostic sync path".

### Step 2: Implement Test (guard)
- Define four `SyncConfig` values that differ ONLY in the `apiToken` string, each labeled by source (`static env var`, `static config.json`, `cloud register response`, `cloud login response`). The point of the outline is that the kit cannot tell sources apart — so each source is modeled merely as a distinct token value handed to `SyncConfig` (no live auth call needed; the "source" is irrelevant to the kit by design).
- For each config, run push/pull/delete through a `RecordingExecutor`, capturing requests.
- Assert across all four sources:
  - `Authorization` header shape is `"Bearer " + apiToken` (same shape, token substituted).
  - Routes are exactly `/api/v1/<entity>/push`, `/api/v1/<entity>/pull...`, `/api/v1/<entity>/<id>` respectively.
  - The non-Authorization header set (including `X-AppleSyncKit-Version`, and `Content-Type` where applicable) is identical across all four sources.
- **Verification**: passes against post-004 code.

## Verification Commands

```bash
swift test --filter ModeAgnosticSyncTests
```

## Success Criteria

- All four token sources produce identical requests apart from the token substring.
- No branch in the kit inspects token origin (proven by identical captures).
- Offline; no network.
