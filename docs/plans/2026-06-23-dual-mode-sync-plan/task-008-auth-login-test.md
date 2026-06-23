# Task 008: AuthClient Login Test (Red)

**depends-on**: task-001-auth-value-types, task-002-executor-seam

## Description

Write failing XCTests for `AuthClient.login(email:password:deviceId:) -> AuthResult` against `POST /api/v1/auth/login`, using the injected seam (offline). Cover: a 2xx `{token}` response yields an `AuthResult`; a wrong-password response and a non-existent-tenant response **both** map to the single `AuthError.invalidCredentials` case (no account-existence leak, A4 / best-practices); and error text never reveals which failure occurred nor echoes the body.

This is the RED test of the 008 auth-login group. It is independent of the register group (different scenarios, different method).

## Execution Context

**Task Number**: 008 (test) of 012
**Phase**: Core Features (cloud login)
**Prerequisites**: Tasks 001 (types) and 002 (seam) complete.

## BDD Scenario

```gherkin
Scenario: Log in from a new device
  Given a tenant exists for my email
  And I am on a device with no stored token
  When I log in with correct credentials
  Then I receive an API token
  And the token is persisted to config.json
  And a later sync from this device succeeds

Scenario: Log in with wrong password
  Given a tenant exists for my email
  When I log in with an incorrect password
  Then I receive a generic "invalid credentials" error
  And the error does not reveal whether the tenant exists
  And no token is persisted

Scenario: Log in for a non-existent tenant
  Given no tenant exists for my email
  When I log in with that email
  Then I receive the same generic "invalid credentials" error as a wrong password
  And the error does not reveal that the tenant is missing
```

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Create: `Tests/AppleSyncKitTests/AuthClientLoginTests.swift`

## Steps

### Step 1: Verify Scenario
- Confirm the three login scenarios exist under "Cloud mode login".

### Step 2: Implement Test (Red)
- Using a `RecordingExecutor`:
  - Success: `200` + `{"token":"tok_live_xyz"}` → `login(...)` returns `AuthResult(token:"tok_live_xyz", deviceId:<passed>)`; recorded request is `POST <base>/api/v1/auth/login`, body `{email,password,device_id}`, has `X-AppleSyncKit-Version`, no `Authorization`.
  - Wrong password: executor returns the Worker's invalid-credential status (e.g. `401`) → throws `AuthError.invalidCredentials`.
  - Non-existent tenant: executor returns the **same** generic status/body the Worker uses for unknown accounts → throws the **same** `AuthError.invalidCredentials`. Assert the two thrown errors are `==` (Equatable) so the kit surface cannot distinguish them.
  - Assert the error description reveals neither tenant existence nor the response body.
- **Verification**: FAILS because `AuthClient.login` does not exist.

## Verification Commands

```bash
swift test --filter AuthClientLoginTests
```

## Success Criteria

- Wrong-password and unknown-tenant cases produce an identical `AuthError.invalidCredentials` value.
- No error text leaks account existence or body contents.
- Offline; fails (Red) prior to the 008 impl task.
