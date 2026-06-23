# Best Practices — Dual-Mode Sync

Canonical vocabulary per `_index.md`. "Kit" = this repo; "Worker" = the separate backend repo.

## Security

### End-to-end encryption invariant (mode-independent)

- The Worker stores **only ciphertext**. All encryption/decryption happens client-side in
  `EncryptionService` (AES-GCM, 256-bit key, `recordId|modifiedDate` bound as AAD). This must hold
  byte-identically in self-host mode and cloud mode.
- **`AuthClient` must never touch, derive, transmit, or persist the encryption key.** It obtains an
  API token and nothing else. The key stays a separate per-device base64 env var.
- **Threat model for cloud mode:** the operator is honest-but-curious for content, and content
  confidentiality does **not** depend on operator honesty. The operator can see metadata (record ids,
  timestamps, sizes, tenant identity) but never plaintext. This is the property that makes "use my
  cloud" an acceptable ask. State it plainly in user-facing docs.
- **Forbidden in cloud mode** (each silently breaks the invariant): server-side key escrow, a "forgot
  my key / recover my data" flow, and any server-side search/index over plaintext.
- Keep the AAD binding and the existing tamper-fails-to-decrypt behavior unchanged (already covered by
  `testTamperedAADFailsToDecrypt` / `testWrongKeyFailsToDecrypt`).

### Client API-token handling

- Persist the cloud-obtained token through the **existing** `ConfigStore.saveConfig`
  (`ConfigStore.swift:115`): HTTPS validation + 0o600 temp file + atomic rename + `flock`. Do **not**
  add a second storage path or a new file format.
- The token must never appear in logs, error messages, URLs, or query strings. Sync already passes the
  token only via `Authorization: Bearer`; `AuthClient` sends credentials only in the POST body over
  TLS. Critically, `AuthClient` must **not** copy the existing D1 client habit of folding the response
  body into `SyncError.unknown` — auth bodies contain passwords/tokens. Map to typed `AuthError` cases
  instead.
- HTTPS is enforced via `ConfigStore.validateAPIURL`; route `AuthClient` through it so auth endpoints
  can never be hit over `http://`.
- Logging in does **not** provision a key. A fresh device that logs in but lacks the key can sync
  ciphertext but cannot decrypt — surface this as a clear, non-fatal-to-sync condition (the existing
  `SyncStatusCommand` already reports whether the key is set).

### Server-side tenant isolation (Worker-side spec)

- Tenant identity is derived **server-side from the bearer token only**. Scope every D1 query
  (`push`/`pull`/`delete`) by that tenant.
- **Never trust the client-supplied `device_id`** (pull query + push body) for isolation — it is only
  an own-writes filter, not an authorization boundary. A spoofed `device_id` must not cross tenants.
- A token for tenant A must only ever read/write tenant A rows; cross-tenant access returns
  empty/404, never another tenant's data.
- `MAX_BATCH_SIZE` parity with `D1SyncClient.maxBatchSize = 500` still applies per tenant.

### Auth endpoint hardening (Worker-side, kit cooperates)

- Passwords hashed with a memory-hard KDF: argon2id preferred; scrypt/PBKDF2-via-WebCrypto
  (`crypto.subtle`) is the Workers-runtime-pragmatic fallback. Never store plaintext or a fast hash
  (SHA-256) for passwords.
- Tokens are high-entropy opaque random values; store only `SHA-256(token)`. (A fast hash is fine for
  high-entropy tokens — the slow KDF is only for low-entropy passwords.)
- **No account-existence leak:** wrong-password and unknown-account logins must return the same generic
  error and similar timing. The kit maps both to the single `AuthError.invalidCredentials` case and
  surfaces no server text distinguishing them.
- Registration with a taken email is the one acceptable existence signal (unavoidable for usability) →
  `AuthError.accountExists`, but rate-limited to blunt enumeration.
- Brute-force throttling / backoff / temporary lockout on repeated failed logins.

### Abuse / quotas (cloud mode, Worker-side)

- Rate-limit registration and login per IP and per email.
- Per-tenant quotas: max rows/bytes, max devices, request rate — to bound a hostile free account.
- Consider an invite/registration code or email verification to throttle bulk account creation; spec
  the hook even if deferred.
- Cap auth payload sizes early (auth bodies are tiny; the sync ceilings are 1 MB push / 10 MB pull).

## Performance

- The cursor pull assumes a cheap `updated_at > cursor` scan. Under tenant scoping the Worker **must**
  add the composite index `(tenant_id, entity, updated_at)` or the pull degrades. Kit unaffected.
- The version check is a header comparison + a one-shot stderr write; it adds nothing measurable and
  must never add a round trip.
- `AuthClient` is called once per device onboarding, not on the sync hot path — no batching/pooling
  concerns; reuse the `HTTPClient(.singleton)` like `D1SyncClient`.

## Code quality

- **Keep `AuthClient` a separate `actor`** (alongside `EncryptionService`/`D1SyncClient`). Do not bake
  auth into `D1SyncClient`; the byte-identical sync path must stay provable.
- Mirror existing idioms: `Sendable` boundary types (`AuthResult` like `PushResult`), a dedicated error
  enum (`AuthError` like `EncryptionError`), a pure policy enum (`SyncVersionPolicy` like
  `SyncCursorPolicy`).
- Factor the three `D1SyncClient` header sites into one `applyCommonHeaders` — removes existing
  duplication and gives the version header a single home.
- Tests follow the established injection seam: `ConfigStore.loadFromEnvironment(_:)` already takes an
  injected dictionary; give `AuthClient` a small `Sendable` request-executor protocol so tests inject
  canned `(status, body)` fixtures offline. No live NIO server in unit tests; reserve any real network
  test for an opt-in target. Test `SyncVersionPolicy` as a pure comparison matrix.

## Pitfalls to avoid

- **No mode concepts in the kit.** No `enum Mode { selfHost, cloud }`, no `if cloudMode` branches.
  `AuthClient` is optional; everything downstream sees only a `SyncConfig`. The composition root (CLI)
  decides whether to call `AuthClient`.
- **Don't echo request/response bodies in auth errors** — they carry credentials/tokens.
- **Don't add key escrow or recovery flows** — any server path to plaintext or the key voids the
  no-confidentiality-trust property.
- **Don't widen `SyncConfig`** with `email`, `tenantId`, or `mode`. Tenant lives server-side, derived
  from the token.
- **Don't conflate `device_id` with identity** — it is an own-writes filter only.
- **Version check must be non-fatal and deduped** — warn once per process; a missing header must not
  crash; a mismatch must not block sync (never brick an older client on a Worker bump).
- **Keep "API token" vocabulary** distinct from the *encryption* key; reserve "API key" only for any
  agent child-token context.
- **Don't over-defend.** No redundant nil/empty guards beyond what the existing code does; no
  `try?`-swallowing of auth failures; no `any`/`@unchecked` casts to bypass `Sendable`. Match the
  terse single-responsibility style of `SyncCursorPolicy` / `SyncTimestamp`.
</content>
