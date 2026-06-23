# Dual-Mode Sync: Self-Host + Cloud Service — Design

## Context

`AppleSyncKit` is a generic, entity-agnostic Swift 6 library — the shared **client** behind several
personal sync CLIs (`note`, `event`). It implements one bidirectional, last-write-wins sync
algorithm against a Cloudflare D1 sync Worker, with client-side AES-GCM end-to-end encryption.

Today there is exactly one deployment shape: every user must deploy **their own** Worker and
configure a static API token. The goal of this design is to add a second shape — a **hosted,
multi-tenant cloud service that the author operates**, where other users (and other agents) can
register, log in, and sync — **without giving up self-hosting and without compromising the
entity-agnostic, end-to-end-encrypted design**.

The reframing that drives the whole design: the kit knows the backend through exactly three values,
`SyncConfig(apiURL, apiToken, deviceId)`, and one `Authorization: Bearer <token>` header. The sync
wire protocol carries **no tenant concept** — `device_id` is only an own-writes filter. Therefore
"self-host vs cloud" is purely a **deployment** property of the Worker, never a property of any byte
the client sends. **The kit needs zero mode awareness.** The only genuinely new client capability is
*acquiring* a token in cloud mode (register/login) instead of pasting a static one.

## Discovery Results

Grounded in the kit and both consuming CLIs:

- **Auth is just a token.** `D1SyncClient` (`Sources/AppleSyncKit/Network/D1SyncClient.swift:86,127,169`)
  sends only `Authorization: Bearer <apiToken>` + `Content-Type`. `SyncConfig`
  (`Sources/AppleSyncKit/Models/SyncResults.swift:5-15`) is exactly `apiURL`/`apiToken`/`deviceId`.
- **No tenant/mode/auth symbols exist** anywhere in `Sources/`. The only "version" present is
  `EncryptedCarrier.currentVersion = 1` (payload format, unrelated) — the convention to mirror for a
  kit-owned version constant.
- **Token persistence already exists.** `ConfigStore.saveConfig(_:)`
  (`Sources/AppleSyncKit/Persistence/ConfigStore.swift:115-118`) HTTPS-validates then writes
  `config.json` 0o600 via atomic rename under `flock`. No new persistence path is needed.
- **HTTPS is already enforced** in `ConfigStore.validateAPIURL` (`:60-64`).
- **E2E boundary is intact.** `EncryptionService` (`Sources/AppleSyncKit/Crypto/EncryptionService.swift`)
  runs client-side AES-GCM with `recordId|modifiedDate` bound as AAD; the key is a separate per-device
  base64 env var the backend never sees.
- **Error-enum precedent:** the kit already has two separate enums, `SyncError` (`.notFound`,
  `.invalidInput`, `.unknown`) and `EncryptionError` — so a dedicated `AuthError` enum is consistent
  with the codebase, not a new pattern.
- **Helper-type precedent:** `SyncCursorPolicy` (`Sources/AppleSyncKit/Models/SyncTimestamp.swift:35`)
  is a pure stateless policy enum — the model for a `SyncVersionPolicy`.
- **Consumers wire config identically.** Both `note` and `event` wrap the kit in a `SyncConfigStore`
  enum (namespaces `note-sync`/`event-sync`, prefixes `NOTE`/`EVENT`) exposing `save(SyncConfig)`, and
  both expose a shared `SyncConfigCommand` (`<tool> sync config --api-url --api-token --device-id`)
  plus a `SyncStatusCommand` that already prints a masked token and whether the encryption key is set.
  A cloud `login`/`register` subcommand drops in beside `config`: it obtains a token via the kit's new
  `AuthClient`, then calls the **same** `SyncConfigStore.save(SyncConfig(...))`. Everything downstream
  is untouched.

## Glossary

Canonical labels (and rejected variants, recorded so future readers see what was considered):

| Concept | Canonical label | Rejected / reserved variants |
|---|---|---|
| Deployment where the user runs their own Worker | **self-host mode** | "BYO", "private mode" |
| Deployment where the author hosts a shared service | **cloud mode** | "hosted mode", "SaaS mode" |
| A registered account in cloud mode | **tenant** | "account" (allowed in prose, not as a code identifier) |
| The bearer credential used for sync | **API token** | "API key" — **reserved** only for agent child-token issuance |
| The kit's optional auth component | **AuthClient** | — |
| The backend service (separate repo) | **Worker** | "server", "backend" (prose only) |
| Kit error type for auth failures | **AuthError** (new enum, mirrors `EncryptionError`) | reusing `SyncError.invalidInput` for all auth errors |
| Request version header | **`X-AppleSyncKit-Version`** | `X-API-Version` |
| Response version header | **`X-AppleSyncKit-Server-Version`** | — |
| Version comparison helper | **SyncVersionPolicy** (pure, mirrors `SyncCursorPolicy`) | inline comparison in `D1SyncClient` |
| Auth result value type | **AuthResult** (`token`, `deviceId`; no `tenant`) | — |
| Worker dual-mode env toggle | **`CLOUD_MODE`** | — |

## Requirements

Split by repo. Only group (A) lands in `apple-sync-kit`.

### (A) Kit — `apple-sync-kit` (this repo)

- **A1.** Add an optional `actor AuthClient` (`Sources/AppleSyncKit/Network/AuthClient.swift`) with
  `register(email:password:deviceId:) -> AuthResult` and `login(email:password:deviceId:) -> AuthResult`
  against `POST /api/v1/auth/register` and `/api/v1/auth/login`. Same transport/`actor`/`shutdown()`
  shape as `D1SyncClient`.
- **A2.** `AuthClient` is entirely optional and orthogonal to sync. Self-host users never instantiate
  it. The returned token flows into the existing `SyncConfig.apiToken` and is persisted via the
  existing `ConfigStore.saveConfig(_:)` — **no new persistence schema or file format**.
- **A3.** The sync wire path stays **byte-identical** in both modes. `D1SyncClient` continues to send
  only `Authorization` + `Content-Type` (+ the version header in A4). No tenant id, account id, email,
  or mode flag is ever added to push/pull/delete.
- **A4.** Add an `AuthError` enum (mirrors `EncryptionError`) with at least `.invalidCredentials`
  (used for *both* wrong-password and unknown-account, to avoid an account-existence leak) and
  `.accountExists`. `AuthClient` maps non-2xx responses to typed cases and **never** echoes request or
  response bodies (which contain passwords/tokens) into error text.
- **A5.** Reuse `ConfigStore.validateAPIURL` so `AuthClient` refuses non-HTTPS URLs **before** any
  network call.
- **A6.** Add a kit-owned API version constant and send `X-AppleSyncKit-Version` on every outbound
  request from `D1SyncClient` (factor the three header sites into one private `applyCommonHeaders`).
  Add a pure `SyncVersionPolicy` (mirrors `SyncCursorPolicy`) that compares the client version with
  the Worker's `X-AppleSyncKit-Server-Version` response header and returns `.ok` / `.warn(message)` /
  `.unknown`. On mismatch, emit **one** non-fatal `writeStderr` warning per process; never throw.
- **A7.** `SyncConfig` shape is **unchanged**. No `mode`, `tenant`, or `email` field.
- **A8.** Zero `tenant`/`mode`/`cloud`/`self-host` symbols in the kit's API surface (code
  identifiers). These concepts live only in docs/comments.
- **A9.** Swift 6 strict-concurrency clean: `AuthClient` is an `actor`; `AuthResult`/`AuthError`/
  `SyncVersionPolicy` are `Sendable`.
- **A10.** Tests (XCTest, `Tests/AppleSyncKitTests/`): `AuthClient` request construction +
  HTTPS-refusal + error mapping (offline, via an injected request-executor seam), `SyncVersionPolicy`
  comparison matrix, a regression proving the sync path is identical regardless of token origin, and
  a `saveConfig` round-trip asserting 0o600. Existing tests pass unmodified.
- **A11.** Docs: `README.md`, `README.zh-CN.md`, `CLAUDE.md` describe the optional `AuthClient`, the
  version header, and the self-host-vs-cloud framing, making explicit that the kit is mode-agnostic.
- **A12.** BDD `.feature`-style scenarios precede implementation (captured in `bdd-specs.md` here, then
  realized as XCTest). `swift format lint --strict` clean. No new dependency (AsyncHTTPClient is
  already present).

### (B) Worker — separate repo (design-only here)

- **B1.** One Worker codebase, env toggle `CLOUD_MODE` selecting single-tenant (self-host default)
  vs multi-tenant (cloud).
- **B2.** In cloud mode expose `POST /api/v1/auth/register` and `/api/v1/auth/login` (and optionally
  `POST /api/v1/auth/tokens` for agent child tokens). In self-host mode these are absent and the static
  configured token is honored — today's behavior preserved.
- **B3.** Server-side tenant isolation: every token maps to exactly one tenant; all D1 reads/writes are
  scoped by that tenant, derived from the token — **never** from the client `device_id`. A token can
  never read/write another tenant's rows.
- **B4.** Per-tenant quotas + abuse controls: rate-limit auth and sync endpoints; cap rows/bytes/devices;
  throttle registration (cloud mode only).
- **B5.** Storage: shared D1 + `tenant_id` column with composite index `(tenant_id, entity, updated_at)`
  (primary); DO-per-tenant SQLite as a documented escape hatch. Keep `MAX_BATCH_SIZE` in lockstep with
  the kit's `maxBatchSize = 500`.
- **B6.** Read `X-AppleSyncKit-Version`; echo `X-AppleSyncKit-Server-Version`; reject/ignore by policy.
  A Worker ignoring an unknown request header stays backward-compatible (header ships first, enforcement
  later).
- **B7.** Passwords hashed with a memory-hard KDF (argon2id preferred; scrypt/PBKDF2-via-WebCrypto as
  the Workers-runtime-pragmatic fallback). Tokens stored only as `SHA-256(token)`. The Worker never
  holds plaintext user data or the encryption key.

## Rationale

- **Kit stays mode-agnostic because the protocol's only authority input is the token, and the token
  already fully determines server-side identity.** "Self-host vs cloud" is a deployment property of the
  Worker, not of any client byte. Pushing mode-awareness into the kit would invent a distinction the
  wire protocol does not have — pure accidental complexity and a second code path to test for zero
  behavioral gain. This matches the codebase's existing discipline (entity-agnostic, no composition
  root, backend known only as `SyncConfig`).
- **End-to-end encryption is what makes a hosted service an acceptable ask, not a trust imposition.**
  The key never leaves devices; the Worker is a zero-knowledge ciphertext blob store. So adopting cloud
  mode does not require trusting the operator with content confidentiality — the cloud threat model
  collapses to availability/abuse, not confidentiality.
- **Bitwarden/Vaultwarden is the proven precedent.** One client, a single server-URL setting selects
  official-hosted vs self-hosted, vault end-to-end encrypted so the host is untrusted-by-design.
  AppleSyncKit mirrors this exactly: one kit, `apiURL` + `apiToken` select the backend, ciphertext-only
  storage. Cloud mode is the convenience tier; self-host is always available; neither forks the client.
- **One Worker codebase with an env toggle** lets self-hosters run the exact code the author runs
  (trust + maintainability), and lets the author dogfood single-tenant before enabling multi-tenant.

## Detailed Design

See the companion documents. In brief:

- **`AuthClient` (kit):** an `actor` mirroring `D1SyncClient` — owns an `HTTPClient(.singleton)`, has
  `shutdown()`, validates HTTPS via `ConfigStore.validateAPIURL`, POSTs `{email,password,device_id}`,
  decodes `{token}` into a `Sendable AuthResult`, maps non-2xx to `AuthError` without echoing bodies.
  The consuming CLI (composition root) calls it, builds `SyncConfig`, and persists via `saveConfig`.
- **Version header (kit):** one constant + `applyCommonHeaders` on `D1SyncClient`; `SyncVersionPolicy`
  pure comparison; one-shot non-fatal stderr warning.
- **Worker (separate repo):** `CLOUD_MODE` toggle; token→tenant table keyed by `SHA-256(token)`;
  shared D1 + `tenant_id` with the composite cursor index; per-tenant quotas; argon2id passwords.
- **Consumers (`note`, `event`):** add a `login`/`register` subcommand beside the existing `config`
  command in their `SharedSyncCommands`; reuse `SyncConfigStore.save`. No other consumer change.

## Design Documents

- [`architecture.md`](architecture.md) — system overview, components, data structures, integration
  points, the storage decision and its rejected alternative.
- [`bdd-specs.md`](bdd-specs.md) — full Gherkin scenarios (self-host regression, cloud register/login,
  mode-agnostic sync, version compatibility, E2E-in-cloud, `@worker` tenant isolation + abuse).
- [`best-practices.md`](best-practices.md) — security (E2E invariant, token handling, tenant
  isolation, auth hardening, abuse), performance, code quality, and pitfalls to avoid.
</content>
</invoke>
