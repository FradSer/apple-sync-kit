# Task 005: Self-Host Static-Token Regression Guard (Test-only)

**depends-on**: task-002-executor-seam, task-004-version-header-impl

## Description

Lock the self-host regression invariant (requirements A3, A7): config resolved from env vars or from `config.json` produces a `SyncConfig` whose static token is used as the bearer **unchanged**, with **no auth endpoint ever contacted**. This is an invariant guard — it must already pass against the post-004 code (no `AuthClient` is involved in plain config resolution). It goes red only if a future change routes self-host config through auth or mutates the token.

**Why test-only (no impl pair):** there is no new production behavior to build — the guarantee is that adding cloud mode changes nothing for self-host users. The test pins that. (This is an intentional exception to test/impl pairing; see `_index.md` "Note on guard tests".)

## Execution Context

**Task Number**: 005 of 012
**Phase**: Refinement (regression guard)
**Prerequisites**: Tasks 002 (seam, to capture the bearer) and 004 impl (final header set) complete.

## BDD Scenario

```gherkin
Scenario: Sync with a static API token from environment variables
  Given the env vars for API URL and a static API token are set
  And the encryption key env var is exported
  When I run a sync
  Then config resolves from the environment without contacting any auth endpoint
  And the sync uses the static API token as a bearer token unchanged

Scenario: Sync with a static API token from config.json
  Given no sync env vars are set
  And a config.json holds an HTTPS API URL and a static API token
  When I run a sync
  Then config resolves from the file without contacting any auth endpoint
  And the sync proceeds unchanged
```

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Create: `Tests/AppleSyncKitTests/SelfHostRegressionTests.swift`

## Steps

### Step 1: Verify Scenario
- Confirm both self-host scenarios exist under "Self-host mode regression".

### Step 2: Implement Test (guard)
- Env path: build a `ConfigStore(namespace:prefix:)`, call `loadFromEnvironment(_:)` with an injected dict holding `*_SYNC_API_URL` + `*_SYNC_API_TOKEN`. Construct `D1SyncClient` with that config and a `RecordingExecutor` (the task-004 support stub). Run a `pull`; assert the recorded `Authorization` header equals `"Bearer <the-static-token>"` byte-for-byte, and that no request URL contains `/api/v1/auth/`.
- File path: write a temp `config.json` (HTTPS URL + static token) into an isolated temp `~/.config` namespace dir, call `loadConfig`, repeat the bearer + no-auth-endpoint assertions. Clean up the temp dir.
- Assert no `AuthClient` is constructed anywhere in either path.
- **Verification**: passes against post-004 code (guard holds today).

## Verification Commands

```bash
swift test --filter SelfHostRegressionTests
```

## Success Criteria

- Both env and file resolution produce a bearer identical to the configured static token.
- No request targets an `/api/v1/auth/...` route.
- Test is offline (RecordingExecutor) and cleans up any temp files it creates.
