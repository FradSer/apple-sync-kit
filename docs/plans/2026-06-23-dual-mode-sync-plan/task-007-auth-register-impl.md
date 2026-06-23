# Task 007: AuthClient Scaffolding and Register Impl (Green)

**depends-on**: task-007-auth-register-test

## Description

Create the optional `actor AuthClient` mirroring `D1SyncClient` (architecture.md), and implement `register` so `task-007-auth-register-test` passes. Owns the request path through the injected `HTTPRequestExecutor`, validates HTTPS via `ConfigStore.validateAPIURL` before any network call (A5), POSTs `{email,password,device_id}` to `/api/v1/auth/register`, sends `X-AppleSyncKit-Version` and no `Authorization`, decodes `{token}` into `AuthResult` (ignoring any `tenant_id` the Worker returns), and maps non-2xx to `AuthError` **without echoing bodies** (A4, best-practices "Don't echo request/response bodies in auth errors").

This is the GREEN impl of the 007 auth-register group; it runs after `task-007-auth-register-test`.

## Execution Context

**Task Number**: 007 (impl) of 012
**Phase**: Core Features (cloud registration)
**Prerequisites**: `task-007-auth-register-test` exists and fails.

## BDD Scenario

```gherkin
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

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Create: `Sources/AppleSyncKit/Network/AuthClient.swift`

## Steps

### Step 1: Define the actor
- Contract (signatures only):

```swift
public actor AuthClient {
  public init(baseURL: String, executor: HTTPRequestExecutor = RealHTTPRequestExecutor())
  public func shutdown() async throws
  public func register(email: String, password: String, deviceId: String) async throws -> AuthResult
  // login added in task 008 impl
}
```

- Reuse the task-002 `HTTPRequestExecutor` seam (default real). Mirror `D1SyncClient`'s `shutdown()`.
- HTTPS validation: route the base URL through `ConfigStore.validateAPIURL` **before** building/sending any request. Whether validated in `init` or at call time, task-007-test's "0 executor calls on http://" assertion must hold.

### Step 2: Implement `register`
- Build `POST <base>/api/v1/auth/register`, JSON body `{ "email":..., "password":..., "device_id":... }`, header `X-AppleSyncKit-Version: SyncAPIVersion.current`, NO `Authorization`.
- Execute via the seam. On 2xx decode `{ "token": ... }` → `AuthResult(token:deviceId:)`; ignore any `tenant_id`.
- Error mapping (a private helper reused by `login` in task 008 impl): map the taken-email status → `.accountExists`; other non-2xx → `.httpStatus(code)`. Never fold the response/request body into the error.

### Step 3: Verify (Green)
- `swift test --filter AuthClientRegisterTests` passes; full suite passes.

## Verification Commands

```bash
swift test --filter AuthClientRegisterTests
swift test
swift format lint --strict --recursive Sources
```

## Success Criteria

- `AuthClient` is an `actor`; `AuthResult` returned is `Sendable`.
- HTTPS refused before any network call.
- No request/response body, password, or token appears in any thrown error.
- No `tenant`/`mode`/`email`-typed field leaks into kit API beyond the `register` parameters.
- `swift format lint --strict` clean.
