# Task 009: Client-Side Encryption Invariant in Cloud Mode Guard (Test-only)

**depends-on**: task-007-auth-register-impl

## Description

Lock the zero-knowledge invariant for cloud mode (best-practices "End-to-end encryption invariant"): obtaining a token via cloud login provisions **only** a token; the encryption key stays a separate per-device secret. A device holding a cloud token but no key can receive ciphertext but cannot decrypt, failing with a "key not configured" / decryption error. Also assert the `AuthClient` API surface has no key parameter/return — it can never touch, derive, transmit, or persist the encryption key.

**Why test-only (no impl pair):** the property already holds — `EncryptionService` is the sole decryption path and `AuthClient` has no key access. This guard fails only if a future change adds a key path to auth. (Intentional exception to test/impl pairing; see `_index.md` "Note on guard tests".)

## Execution Context

**Task Number**: 009 of 012
**Phase**: Refinement (regression guard)
**Prerequisites**: `task-007-auth-register-impl` (`AuthClient` exists).

## BDD Scenario

```gherkin
Scenario: Cloud sync still requires the local encryption key to read content
  Given a SyncConfig whose apiToken is "tok_live_abc123" obtained from cloud login
  And the encryption key env var is not set
  When I attempt to decrypt pulled records
  Then decryption fails with "key not configured"
  And no plaintext was ever sent to the Worker

Scenario: A new logged-in device without the key cannot read content
  Given a new device holding apiToken "tok_live_abc123" from a prior cloud login
  And the device does not have the encryption key
  When it pulls records
  Then it receives only ciphertext
  And it cannot decrypt any record until the key is provided
```

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Create: `Tests/AppleSyncKitTests/CloudEncryptionInvariantTests.swift`

## Steps

### Step 1: Verify Scenario
- Confirm both E2E-in-cloud scenarios exist under "Encryption is client-side in cloud mode".

### Step 2: Implement Test (guard)
- "Key not configured" path: drive whatever existing API surfaces the `keyNotConfigured` condition (`EncryptionError.keyNotConfigured`). Assert that, with no key available, the decrypt path yields `EncryptionError.keyNotConfigured(_)` and that a `SyncConfig` carrying a cloud-style token does not change this.
- Ciphertext-only: encrypt a payload with a known key (as `EncryptionServiceTests` does), then attempt to decrypt the resulting ciphertext with a different/absent key and assert failure (`decryptionFailed`/`keyNotConfigured`) — i.e. a logged-in device without the key sees only ciphertext.
- API-surface guard: assert (by construction/compilation in the test) that `AuthClient.register`/`login` take only `email`/`password`/`deviceId` and return `AuthResult(token, deviceId)` — no key parameter, no key field. Document the intent in a comment.
- **Verification**: passes against post-007 code.

## Verification Commands

```bash
swift test --filter CloudEncryptionInvariantTests
```

## Success Criteria

- Decryption without the key fails with the modeled key/decryption error regardless of token origin.
- The test demonstrates `AuthClient` exposes no key parameter or field.
- Offline; reuses the encryption test idioms from `EncryptionServiceTests`.
