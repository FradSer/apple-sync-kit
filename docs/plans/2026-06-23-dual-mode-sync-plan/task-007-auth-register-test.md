# Task 007: AuthClient Register Test (Red)

**depends-on**: task-001-auth-value-types, task-002-executor-seam

## Description

Write failing XCTests for `AuthClient.register(email:password:deviceId:) -> AuthResult` against `POST /api/v1/auth/register`, using the injected `HTTPRequestExecutor` seam (offline). Cover: a 2xx `{ "token": ... }` response yields an `AuthResult` with that token and the passed `deviceId`; an "already taken" response maps to `AuthError.accountExists` with no token returned; a non-HTTPS base URL is refused **before any network call**; and error text never echoes the request/response body (which carries password/token).

This is the RED test of the 007 auth-register group.

## Execution Context

**Task Number**: 007 (test) of 012
**Phase**: Core Features (cloud registration)
**Prerequisites**: Tasks 001 (types) and 002 (seam) complete.

## BDD Scenario

```gherkin
Scenario: Register a new tenant and persist the API token
  Given a cloud auth endpoint over HTTPS
  And no existing tenant for my email
  When I register with a fresh email and password
  Then I receive an API token
  And the token is persisted to config.json with mode 0o600
  And a later sync uses that token and succeeds

Scenario: Register with an already-taken email
  Given a tenant already exists for my email
  When I register with that email
  Then I receive a clear "account already exists" error
  And no token is persisted

Scenario: Registration is rejected over plain HTTP
  Given an auth endpoint URL that uses http rather than https
  When I attempt to register
  Then registration is refused before any network call
  And the error states HTTPS is required
```

(The 0o600-persistence clause of scenario 1 is verified separately in task 010; here the focus is the register call contract.)

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Create: `Tests/AppleSyncKitTests/AuthClientRegisterTests.swift`

## Steps

### Step 1: Verify Scenario
- Confirm the three registration scenarios exist under "Cloud mode registration".

### Step 2: Implement Test (Red)
- Use a `RecordingExecutor` (task-004 support) returning canned responses.
- `async throws` tests (mirror `EncryptionServiceTests` async style):
  - Success: executor returns `200` + `{"token":"tok_live_abc123"}`; assert `register(...)` returns `AuthResult(token: "tok_live_abc123", deviceId: <passed>)`. Assert the recorded request is `POST <base>/api/v1/auth/register`, JSON body `{email,password,device_id}`, carries `X-AppleSyncKit-Version`, and carries NO `Authorization` header (pre-auth endpoint).
  - Account exists: executor returns the Worker's taken-email status (e.g. `409`); assert it throws `AuthError.accountExists`.
  - HTTPS refusal: construct `AuthClient(baseURL: "http://insecure.dev")` (or call register on it) and assert it throws before the executor is ever invoked (assert the recording executor's call count is 0). Error must indicate HTTPS required.
  - No body echo: for an unexpected non-2xx, assert the thrown `AuthError.httpStatus(_)` (or its `errorDescription`) contains neither the response body string nor the password.
- **Verification**: FAILS because `AuthClient` does not exist.

## Verification Commands

```bash
swift test --filter AuthClientRegisterTests
```

## Success Criteria

- Tests reference `AuthClient`, `AuthResult`, `AuthError` and fail (Red) prior to the 007 impl task.
- HTTPS-refusal assertion proves no network call precedes validation.
- Offline; no NIO server.
