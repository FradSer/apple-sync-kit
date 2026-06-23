# Task 001: Foundation — Auth Value Types and Version Constant

**depends-on**: _(none)_

## Description

Create the kit-owned, pure value/error types that both the auth feature and the version-check feature build on. No logic bodies beyond what mirrors existing precedent (`EncryptionError.errorDescription`). These are contracts only: a `Sendable` `AuthResult`, a dedicated `AuthError` enum, and a single kit-owned API-version constant.

Per the design glossary and requirements A4, A7, A8, A9: no `tenant`/`mode`/`email`/`cloud`/`self-host` symbols appear in any of these types. `AuthResult` deliberately carries no `tenant` field.

## Execution Context

**Task Number**: 001 of 012
**Phase**: Foundation
**Prerequisites**: None.

## BDD Scenario

These types are the shared contract underpinning the registration, login, and version-compatibility features. Representative downstream scenario:

```gherkin
Scenario: Register with an already-taken email
  Given a tenant already exists for my email
  When I register with that email
  Then I receive a clear "account already exists" error
  And no token is persisted
```

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Create: `Sources/AppleSyncKit/Models/AuthResult.swift`
- Create: `Sources/AppleSyncKit/Errors/AuthError.swift`
- Create: `Sources/AppleSyncKit/Models/SyncAPIVersion.swift` (holds the kit-owned `kitAPIVersion` constant)

## Steps

### Step 1: Define `AuthResult`
- A `public struct AuthResult: Sendable` with exactly `token: String` and `deviceId: String` and a memberwise `public init`.
- No `tenant`/`tenantId`/`email` field. Mirror the shape/visibility of `PushResult` in `Models/SyncResults.swift`.

Contract:
```swift
public struct AuthResult: Sendable {
  public let token: String
  public let deviceId: String
  public init(token: String, deviceId: String)
}
```

### Step 2: Define `AuthError`
- A `public enum AuthError: LocalizedError, Sendable, Equatable` mirroring `EncryptionError` (`Crypto/EncryptionService.swift:106`).
- Cases: `.invalidCredentials` (used for BOTH wrong-password and unknown-account, no existence leak), `.accountExists` (register only), `.httpStatus(Int)` (other non-2xx, status code only).
- `errorDescription` strings must NOT include any request/response body, password, or token. `.httpStatus` renders only the integer.

Contract:
```swift
public enum AuthError: LocalizedError, Sendable, Equatable {
  case invalidCredentials
  case accountExists
  case httpStatus(Int)
  public var errorDescription: String? { /* generic text, no bodies */ }
}
```

### Step 3: Define the kit API version constant
- A single kit-owned constant, integer-major as a `String` (`"1"`), referenced later by both `D1SyncClient` and `AuthClient`. Mirror the `EncryptedCarrier.currentVersion` convention (`Crypto/EncryptedCarrier.swift:13`).
- Expose as a namespaced constant (e.g. `public enum SyncAPIVersion { public static let current = "1" }`) so there is exactly one home for it.

### Step 4: Verify build
- `swift build` compiles; no new dependency added.

## Verification Commands

```bash
swift build
swift format lint --strict --recursive Sources
```

## Success Criteria

- All three files compile under Swift 6 strict concurrency.
- `AuthResult`, `AuthError` are `Sendable`; `AuthError` is `Equatable`.
- No `tenant`/`mode`/`email`/`cloud` identifier appears in any of the three files.
- `errorDescription` never interpolates a body, password, or token.
- `swift format lint --strict` clean for the new files.
