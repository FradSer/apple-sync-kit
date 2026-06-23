# Architecture — Dual-Mode Sync

## System overview

Three repos, three responsibilities. Only the kit is in this repository.

```
┌─────────────────────────┐     register/login (cloud mode only)
│  Consuming CLI           │ ───────────────────────────────────────┐
│  (note / event)          │                                         │
│  composition root        │     sync (both modes, byte-identical)   │
│   - SyncConfigStore.save │ ──────────────────────────────┐        │
│   - login/register cmd   │                                │        │
└───────────┬─────────────┘                                ▼        ▼
            │ uses                              ┌──────────────────────────────┐
            ▼                                   │  Worker (separate repo)        │
┌─────────────────────────┐                    │  CLOUD_MODE toggle             │
│  AppleSyncKit (this repo)│                    │   off → static token, 1 tenant │
│   D1SyncClient (sync)    │ ───── HTTP ──────▶ │   on  → auth + tenant_id scope │
│   AuthClient (NEW)       │ ───── HTTP ──────▶ │       token→tenant, quotas     │
│   EncryptionService      │  (ciphertext only) │   stores ONLY ciphertext       │
│   ConfigStore            │                    └──────────────────────────────┘
└─────────────────────────┘
```

The kit gains exactly one new component (`AuthClient`) and one cross-cutting addition (the version
header + `SyncVersionPolicy`). Nothing else in the kit changes. The "mode" distinction exists only in
the Worker's `CLOUD_MODE` toggle and in the consuming CLI's choice of *whether to call `AuthClient`*.

## Components

### Kit (this repo)

#### `AuthClient` — `Sources/AppleSyncKit/Network/AuthClient.swift` (NEW)

An `actor` mirroring `D1SyncClient` (`D1SyncClient.swift:11-46`): owns an
`HTTPClient(eventLoopGroupProvider: .singleton)`, exposes `shutdown()`, throws kit error types.

```swift
public actor AuthClient {
  private static let apiVersion = "1"                  // shared with D1SyncClient via one constant
  private let baseURL: String                          // HTTPS, validated by caller
  private let httpClient: HTTPClient

  public init(baseURL: String) { /* validate caller-side; HTTPClient(.singleton) */ }
  public func shutdown() async throws { try await httpClient.shutdown() }

  public func register(email: String, password: String, deviceId: String) async throws -> AuthResult
  public func login(email: String, password: String, deviceId: String) async throws -> AuthResult
}
```

- POSTs JSON `{ "email": ..., "password": ..., "device_id": ... }` to
  `\(baseURL)/api/v1/auth/{register,login}`; no `Authorization` header (these are pre-auth endpoints);
  sends `X-AppleSyncKit-Version`.
- Decodes a `{ "token": ... }` body. Any `tenant_id` the Worker returns is **ignored** — the kit stays
  tenant-unaware.
- Maps responses to `AuthError` (below). Never folds the response/request body into error text.
- HTTPS enforced via `ConfigStore.validateAPIURL` before any network call (A5).

#### `AuthResult` — `Sources/AppleSyncKit/Models/` (NEW, `Sendable`)

```swift
public struct AuthResult: Sendable {
  public let token: String
  public let deviceId: String
}
```

Deliberately no `tenant`/`tenantId` field — the kit must not learn the concept.

#### `AuthError` — `Sources/AppleSyncKit/Errors/` (NEW, mirrors `EncryptionError`)

```swift
public enum AuthError: LocalizedError, Sendable, Equatable {
  case invalidCredentials        // wrong password AND unknown account map here (no existence leak)
  case accountExists             // register only; the one acceptable existence signal
  case httpStatus(Int)           // other non-2xx, WITHOUT the response body
}
```

Rationale for a dedicated enum rather than reusing `SyncError.invalidInput`: the no-account-existence-leak
rule requires two failure shapes to collapse to one case, and the kit must avoid echoing bodies that
contain credentials — both are properties of the *type*, so they belong in a purpose-built enum, exactly
as `EncryptionError` is separate from `SyncError`.

#### Version header + `SyncVersionPolicy`

- One kit-owned constant (`apiVersion = "1"`, integer major), referenced by both `D1SyncClient` and
  `AuthClient`. Convention mirrors `EncryptedCarrier.currentVersion` (`EncryptedCarrier.swift:13`).
- `D1SyncClient`: factor the three header-setting sites (`D1SyncClient.swift:86`, `:127`, `:169`) into
  one private `applyCommonHeaders(_:)` that adds `Authorization` + `X-AppleSyncKit-Version`. This also
  removes the existing three-way header duplication.
- `SyncVersionPolicy` — `Sources/AppleSyncKit/Models/` (NEW), pure like `SyncCursorPolicy`
  (`SyncTimestamp.swift:35`):

  ```swift
  public enum SyncVersionPolicy {
    public enum Outcome: Sendable, Equatable { case ok, warn(String), unknown }
    public static func evaluate(client: String, serverHeader: String?) -> Outcome
  }
  ```

  `nil` server header → `.unknown` (old Worker, no crash); equal → `.ok`; different → `.warn(message)`.
- After each `D1SyncClient.execute`, run `SyncVersionPolicy.evaluate` against the
  `X-AppleSyncKit-Server-Version` response header. On `.warn`, emit **one** `writeStderr` line
  (`StandardError.swift`), deduped by a `private var warnedMismatch = false` on the actor. **Never
  throws** — a version skew must not break sync.

### Worker (separate repo — design only)

- **`CLOUD_MODE` toggle.** Off: today's single static-token compare, no auth tables, no `tenant_id`.
  On: auth endpoints + tenant scoping + quotas. Same binary.
- **Auth endpoints (cloud only):** `register` creates the account + first token, returns
  `{ token, tenant_id }`; `login` verifies the password and mints a **new per-device token**, returns
  `{ token, tenant_id }`; optional `tokens` (requires an existing bearer) mints labeled child tokens for
  agents.
- **Token → tenant resolution:** on every sync request, hash the presented bearer, look up
  `token_hash → tenant_id`, reject if missing/revoked, then scope all queries by `tenant_id`. The push
  body's `device_id` (`SyncDTOs.swift:18-25`) stays purely an own-writes filter, **never** an isolation
  signal.

## Data structures

### Worker schema (cloud mode) — design only

```
accounts(tenant_id PK, email UNIQUE, password_hash, created_at)
tokens(token_hash PK, tenant_id FK, label NULL, created_at, last_used_at, revoked_at NULL)
records(tenant_id, entity, id, data /*ciphertext*/, deleted, updated_at, last_modified,
        PRIMARY KEY (tenant_id, entity, id))
  INDEX (tenant_id, entity, updated_at)   -- keeps the cursor pull cheap under tenant scoping
```

- Passwords: argon2id (or scrypt/PBKDF2-via-WebCrypto) with per-user salt.
- Tokens: store only `SHA-256(token)` (high-entropy random 32-byte base64url token → fast hash is
  sufficient; no slow KDF needed, unlike passwords).
- Revocation: set `revoked_at` (per-device logout); account kill = revoke all rows for the tenant. The
  token table *is* the allowlist, checked per request via one indexed lookup.

### Kit — no schema change

`config.json` keeps the existing three-field `SyncConfig`. The cloud-obtained token lands in
`apiToken`. No migration.

## Storage decision: shared D1 + `tenant_id` (primary) vs DO-per-tenant (rejected)

**Chosen: shared D1 + `tenant_id` column + composite index.** Rejected DO-per-tenant for now.

| Dimension | Shared D1 (chosen) | DO-per-tenant SQLite (rejected) |
|---|---|---|
| Storage ceiling | 10 GB per database (hard) | 10 GB per object (per tenant) |
| Isolation | logical (`tenant_id` filter) | physical (object per tenant) |
| Wire protocol impact | none (`WHERE tenant_id = ?` server-side) | none either |
| Migration single→multi | add nullable column → backfill → index → NOT NULL | must shard/route up front |
| Operational complexity | low (one schema, one DB) | higher (stub routing, per-object lifecycle/migrations) |
| Consistency | per-DB strong | per-object strong, single-threaded |

Rationale: the wire protocol is identical under either choice, so DO buys isolation the kit cannot even
observe, at real added Worker complexity. Because data is already E2E ciphertext, the strongest argument
for DO physical isolation (plaintext blast radius) is largely moot — a `tenant_id` leak exposes
ciphertext, not content. Scale is personal/small-group; shared D1's 10 GB holds tens of millions of
small ciphertext rows, and cursor pagination already exists. **Escape hatch:** if one tenant ever needs
> 10 GB or hard physical isolation, that tenant alone moves to a DO addressed by `idFromName(tenantId)`,
routed by token — still invisible to the kit.

## Integration points

- **Kit → Worker (sync):** unchanged `GET/POST/DELETE /api/v1/<entity>/…` + `Authorization: Bearer`
  + new `X-AppleSyncKit-Version`. `maxBatchSize = 500` must equal the Worker's `MAX_BATCH_SIZE`.
- **Kit → Worker (auth, cloud only):** `POST /api/v1/auth/{register,login}` → `{ token }`.
- **Kit → consumer:** `AuthClient` returns `AuthResult`; the CLI builds `SyncConfig` and calls the
  existing `ConfigStore.saveConfig`.
- **Consumer CLIs (`note`, `event`):** add a `login`/`register` subcommand in `SharedSyncCommands`
  beside the current `SyncConfigCommand`; it constructs `AuthClient(baseURL:)`, calls
  `login`/`register`, then `SyncConfigStore.save(SyncConfig(apiURL:apiToken:deviceId:))`. The existing
  `SyncStatusCommand` already masks the token and reports key presence — no change needed there.
- **Encryption:** unchanged. Logging in provisions a token only; the encryption key stays a separate,
  out-of-band, per-device env var. A logged-in device without the key syncs ciphertext but cannot
  decrypt — correct, and surfaced as a clear non-fatal condition.

## Rollout ordering (avoids version-drift breakage)

1. Kit ships the `X-AppleSyncKit-Version` request header (old Workers ignore unknown headers → safe).
2. Worker echoes `X-AppleSyncKit-Server-Version` and adds the `CLOUD_MODE` path + auth endpoints.
3. Kit ships `AuthClient`; consumers add `login`/`register`.
4. Enforcement (rejecting incompatible versions) comes last, once both sides honor the header.
</content>
