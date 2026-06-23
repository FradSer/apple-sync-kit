# Task 010: Cloud-Token saveConfig 0o600 Round-Trip Test (Test-only)

**depends-on**: task-001-auth-value-types

## Description

Lock requirement A10's persistence clause and the persistence half of the "Register a new tenant and persist the API token" scenario: a token obtained in cloud mode is persisted through the **existing** `ConfigStore.saveConfig(_:)` path — HTTPS-validated, written 0o600 via atomic rename — with **no new persistence schema or file format** (A2, best-practices "Do not add a second storage path"). The test round-trips a `SyncConfig` built from an `AuthResult.token` and asserts the on-disk `config.json` is mode 0o600 and decodes back to the same three fields.

**Why test-only (no impl pair):** `saveConfig` already exists (`ConfigStore.swift:115`); this guard pins that cloud tokens reuse it and that the file mode is correct. (Intentional exception to test/impl pairing; see `_index.md` "Note on guard tests".)

## Execution Context

**Task Number**: 010 of 012
**Phase**: Refinement (regression guard)
**Prerequisites**: `task-001-auth-value-types` (`AuthResult` exists).

## BDD Scenario

```gherkin
Scenario: Register a new tenant and persist the API token
  Given a cloud auth endpoint over HTTPS
  And no existing tenant for my email
  When I register with a fresh email and password
  Then I receive an API token
  And the token is persisted to config.json with mode 0o600
  And a later sync uses that token and succeeds
```

(This task verifies the "persisted to config.json with mode 0o600" clause; the register call itself is covered by the 007 group.)

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Create: `Tests/AppleSyncKitTests/CloudTokenPersistenceTests.swift`

## Steps

### Step 1: Verify Scenario
- Confirm the registration-persistence scenario exists under "Cloud mode registration".

### Step 2: Implement Test (guard)
- Use a `ConfigStore` pointed at an isolated temporary namespace directory (override `HOME`/use a temp dir under the scratch path) so the real user config is never touched.
- Build `AuthResult(token: "tok_live_abc123", deviceId: "device-1")`, construct `SyncConfig(apiURL: "https://example.workers.dev", apiToken: result.token, deviceId: result.deviceId)`, and call `store.saveConfig(_:)`.
- Assertions:
  - The written `config.json` exists and `stat` reports permission bits `0o600`.
  - Re-decoding the file yields a `SyncConfig` equal in `apiURL`/`apiToken`/`deviceId`.
  - No additional file (no new schema/format) is created beyond `config.json`.
- Clean up the temp directory.
- **Verification**: passes against existing `saveConfig`.

## Verification Commands

```bash
swift test --filter CloudTokenPersistenceTests
```

## Success Criteria

- `config.json` is written with mode 0o600 and round-trips the token.
- Only the existing `config.json` path is used — no new persistence file appears.
- Test isolates and cleans up its temp config directory.
