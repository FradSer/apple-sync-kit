# Task 008: AuthClient Login Impl (Green)

**depends-on**: task-008-auth-login-test, task-007-auth-register-impl

## Description

Add `login` to the `AuthClient` actor so `task-008-auth-login-test` passes. Reuse the request-build and error-mapping helpers created in `task-007-auth-register-impl` (this is why this task depends on the 007 impl — `login` extends the same actor). POST `{email,password,device_id}` to `/api/v1/auth/login`, decode `{token}` → `AuthResult`, and map both wrong-password and unknown-account responses to the single `AuthError.invalidCredentials` (no existence leak), never echoing bodies.

This is the GREEN impl of the 008 auth-login group; it runs after `task-008-auth-login-test`.

## Execution Context

**Task Number**: 008 (impl) of 012
**Phase**: Core Features (cloud login)
**Prerequisites**: `task-008-auth-login-test` exists and fails; `task-007-auth-register-impl` created the `AuthClient` actor + shared helpers.

## BDD Scenario

```gherkin
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

- Modify: `Sources/AppleSyncKit/Network/AuthClient.swift`

## Steps

### Step 1: Implement `login`
- Signature:

```swift
public func login(email: String, password: String, deviceId: String) async throws -> AuthResult
```

- Mirror `register`: HTTPS already validated; build `POST /api/v1/auth/login`, same headers (`X-AppleSyncKit-Version`, no `Authorization`), execute via the seam, decode `{token}` → `AuthResult`.
- Error mapping: map the Worker's invalid-credential status (covering BOTH wrong password and unknown account) to `AuthError.invalidCredentials`. Do not introduce any case or text that distinguishes the two. `.accountExists` is NOT used by login.
- Factor any shared POST/decode/error-map logic with `register` into a private helper to avoid duplication.

### Step 2: Verify (Green)
- `swift test --filter AuthClientLoginTests` passes; full suite passes.

## Verification Commands

```bash
swift test --filter AuthClientLoginTests
swift test
swift format lint --strict --recursive Sources
```

## Success Criteria

- Wrong-password and unknown-tenant inputs both yield `AuthError.invalidCredentials`.
- No body/credential text in any error.
- Shared logic factored with `register`; no copy-paste divergence.
- `swift format lint --strict` clean.
