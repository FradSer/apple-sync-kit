# Dual-Mode Sync (Self-Host + Cloud) — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Load `superpowers:executing-plans` skill using the Skill tool to implement this plan task-by-task.

**Goal:** Add an optional, entity-agnostic cloud-auth capability (`AuthClient` register/login) and a non-fatal client/server API-version check to `AppleSyncKit`, while keeping the sync wire path byte-identical and the kit free of any tenant/mode concept.

**Architecture:** The kit knows the backend only through `SyncConfig(apiURL, apiToken, deviceId)` and one `Authorization: Bearer` header, so "self-host vs cloud" is purely a Worker deployment property. The only new client capability is *acquiring* a token in cloud mode via a separate optional `actor AuthClient` that mirrors `D1SyncClient`. A kit-owned `X-AppleSyncKit-Version` header plus a pure `SyncVersionPolicy` adds version-drift warnings without ever blocking sync.

**Tech Stack:** Swift 6.2 (strict concurrency, Swift 6 language mode), SwiftNIO `AsyncHTTPClient` (already a dependency), XCTest, Apple `swift-format`.

**Design Support:**
- [BDD Specs](../2026-06-23-dual-mode-sync-design/bdd-specs.md)
- [Architecture](../2026-06-23-dual-mode-sync-design/architecture.md)
- [Best Practices](../2026-06-23-dual-mode-sync-design/best-practices.md)

## Context

Today there is exactly one deployment shape: every user deploys their own Worker and configures a static API token. The design adds a second shape — a hosted multi-tenant cloud service the author operates — *without* giving up self-hosting and *without* compromising the entity-agnostic, end-to-end-encrypted design. The reframing that drives the plan: the sync protocol carries no tenant concept (`device_id` is only an own-writes filter), so the kit needs **zero** mode awareness. Only group (A) of the design lands in this repo; the Worker (group B) and the six `@worker` BDD scenarios live in a separate repo.

Two cross-cutting refactors enable test-first work without a live network: a `Sendable` request-executor seam (so `D1SyncClient` and `AuthClient` requests can be asserted offline against canned `(status, headers, body)` fixtures), and factoring the three duplicated `D1SyncClient` header sites into one `applyCommonHeaders`.

| Aspect | Current State | Target State |
|--------|--------------|--------------|
| Token acquisition | Static token pasted into env/`config.json` only | Static token **or** cloud `register`/`login` via optional `AuthClient` |
| Sync wire path | `Authorization` + `Content-Type` on push/pull/delete | Byte-identical + one new `X-AppleSyncKit-Version` request header; no tenant/mode byte ever added |
| `D1SyncClient` HTTP | Constructs `HTTPClient(.singleton)` directly; three duplicated header sites | Requests routed through an injectable `HTTPRequestExecutor` (default real); one `applyCommonHeaders` |
| Version awareness | None (only `EncryptedCarrier.currentVersion`, unrelated) | Kit-owned `SyncAPIVersion.current` + pure `SyncVersionPolicy`; one-shot non-fatal stderr warning on mismatch |
| Error types | `SyncError`, `EncryptionError` | + `AuthError` (`.invalidCredentials`, `.accountExists`, `.httpStatus`), never echoing credential-bearing bodies |
| `SyncConfig` shape | `apiURL`/`apiToken`/`deviceId` | **Unchanged** — no `mode`/`tenant`/`email` field |

## Task ID Convention

Paired Red/Green tasks share the same NNN group and feature slug, differing only by `-test`/`-impl` suffix (e.g. `task-003-version-policy-test.md` + `task-003-version-policy-impl.md`). Within a group the `-test` task always runs before the `-impl` task (enforced by the impl's `depends-on` of its paired test). Cross-feature `depends-on` references the group NNN. Guard tasks (005, 006, 009, 010) are intentionally test-only — they lock invariants that already hold and have no impl pair (see "Note on guard tests" below).

## Execution Plan

```yaml
tasks:
  - id: "001"
    subject: "Foundation: auth value types and version constant"
    slug: "auth-value-types"
    type: "setup"
    depends-on: []
  - id: "002"
    subject: "Foundation: HTTPRequestExecutor seam and D1SyncClient injection refactor"
    slug: "executor-seam"
    type: "refactor"
    depends-on: []
  - id: "003"
    subject: "SyncVersionPolicy comparison matrix test"
    slug: "version-policy-test"
    type: "test"
    depends-on: []
  - id: "003"
    subject: "SyncVersionPolicy implementation"
    slug: "version-policy-impl"
    type: "impl"
    depends-on: ["003-version-policy-test"]
  - id: "004"
    subject: "D1SyncClient common headers and warn-once test"
    slug: "version-header-test"
    type: "test"
    depends-on: ["002", "003"]
  - id: "004"
    subject: "D1SyncClient version header and version-check wiring"
    slug: "version-header-impl"
    type: "impl"
    depends-on: ["004-version-header-test"]
  - id: "005"
    subject: "Self-host static-token regression guard"
    slug: "selfhost-regression-test"
    type: "test"
    depends-on: ["002", "004"]
  - id: "006"
    subject: "Mode-agnostic identical-request guard"
    slug: "mode-agnostic-test"
    type: "test"
    depends-on: ["002", "004"]
  - id: "007"
    subject: "AuthClient register test"
    slug: "auth-register-test"
    type: "test"
    depends-on: ["001", "002"]
  - id: "007"
    subject: "AuthClient scaffolding and register impl"
    slug: "auth-register-impl"
    type: "impl"
    depends-on: ["007-auth-register-test"]
  - id: "008"
    subject: "AuthClient login test"
    slug: "auth-login-test"
    type: "test"
    depends-on: ["001", "002"]
  - id: "008"
    subject: "AuthClient login impl"
    slug: "auth-login-impl"
    type: "impl"
    depends-on: ["008-auth-login-test", "007"]
  - id: "009"
    subject: "Client-side encryption invariant in cloud mode guard"
    slug: "e2e-cloud-test"
    type: "test"
    depends-on: ["007"]
  - id: "010"
    subject: "Cloud-token saveConfig 0o600 round-trip test"
    slug: "saveconfig-roundtrip-test"
    type: "test"
    depends-on: ["001"]
  - id: "011"
    subject: "Docs: AuthClient, version header, mode-agnostic framing"
    slug: "docs-update"
    type: "docs"
    depends-on: ["004", "008"]
  - id: "012"
    subject: "Final verification: build, test, lint"
    slug: "final-verification"
    type: "verify"
    depends-on: ["004", "005", "006", "008", "009", "010", "011"]
```

**Task File References (for detailed BDD scenarios):**
- [Task 001: Foundation — auth value types and version constant](./task-001-auth-value-types.md)
- [Task 002: Foundation — HTTPRequestExecutor seam and D1SyncClient injection refactor](./task-002-executor-seam.md)
- [Task 003 (test): SyncVersionPolicy comparison matrix test](./task-003-version-policy-test.md)
- [Task 003 (impl): SyncVersionPolicy implementation](./task-003-version-policy-impl.md)
- [Task 004 (test): D1SyncClient common headers and warn-once test](./task-004-version-header-test.md)
- [Task 004 (impl): D1SyncClient version header and version-check wiring](./task-004-version-header-impl.md)
- [Task 005: Self-host static-token regression guard](./task-005-selfhost-regression-test.md)
- [Task 006: Mode-agnostic identical-request guard](./task-006-mode-agnostic-test.md)
- [Task 007 (test): AuthClient register test](./task-007-auth-register-test.md)
- [Task 007 (impl): AuthClient scaffolding and register impl](./task-007-auth-register-impl.md)
- [Task 008 (test): AuthClient login test](./task-008-auth-login-test.md)
- [Task 008 (impl): AuthClient login impl](./task-008-auth-login-impl.md)
- [Task 009: Client-side encryption invariant in cloud mode guard](./task-009-e2e-cloud-test.md)
- [Task 010: Cloud-token saveConfig 0o600 round-trip test](./task-010-saveconfig-roundtrip-test.md)
- [Task 011: Docs — AuthClient, version header, mode-agnostic framing](./task-011-docs-update.md)
- [Task 012: Final verification — build, test, lint](./task-012-final-verification.md)

## BDD Coverage

All **14 kit-scoped** scenarios in `bdd-specs.md` are covered. The **6 `@worker`-tagged** scenarios are explicitly out of this repo's scope (separate Worker repo) per the header note in `bdd-specs.md`; they are listed below as design-only with no kit task, not orphaned.

| BDD Scenario (Feature) | Covering task(s) |
|---|---|
| Sync with a static API token from environment variables (Self-host regression) | 005 |
| Sync with a static API token from config.json (Self-host regression) | 005 |
| Register a new tenant and persist the API token (Cloud registration) | 007, 010 (0o600 persistence) |
| Register with an already-taken email (Cloud registration) | 007 |
| Registration is rejected over plain HTTP (Cloud registration) | 007 |
| Log in from a new device (Cloud login) | 008 |
| Log in with wrong password (Cloud login) | 008 |
| Log in for a non-existent tenant (Cloud login) | 008 |
| Sync behaves identically for any token source (Mode-agnostic) | 006 |
| Client and Worker API versions match (Version compatibility) | 003 (policy), 004 (client) |
| Worker reports a different API version (Version compatibility) | 003 (policy), 004 (client) |
| Worker omits the API version header (Version compatibility) | 003 (policy), 004 (client) |
| Version warning is emitted at most once per process (Version compatibility) | 004 |
| Cloud sync still requires the local encryption key (E2E in cloud) | 009 |
| A new logged-in device without the key cannot read content (E2E in cloud) | 009 |
| **@worker** A token cannot access another tenant's data | design-only (Worker repo) — no kit task |
| **@worker** A spoofed device id does not cross tenant boundaries | design-only (Worker repo) — no kit task |
| **@worker** Repeated registration attempts are rate-limited | design-only (Worker repo) — no kit task |
| **@worker** Repeated failed logins are throttled | design-only (Worker repo) — no kit task |
| **@worker** Self-host deployment with CLOUD_MODE off | design-only (Worker repo) — no kit task |
| **@worker** Cloud deployment with CLOUD_MODE on | design-only (Worker repo) — no kit task |

**Note on guard tests (005, 006, 009, 010):** these lock invariants that already hold against existing code (token-origin-agnostic sync path, client-side encryption, 0o600 persistence). They are not classic Red→Green pairs; they go red only if a future change breaks the invariant. They are intentionally test-only (no impl pair) — this is a deliberate exception to the test/impl pairing rule, recorded here so reviewers do not flag a "missing impl".

## Dependency Chain

```
001 (value types) ──────────────────────────┐
                                             ├─→ 007-test ─→ 007-impl ─┬─→ 008-impl
002 (executor seam) ─────────────────────────┤                        │
   │                                         ├─→ 008-test ────────────┘
   │                                         │        │
   │   003-test ─→ 003-impl (version policy) │   007-impl ─→ 009 (e2e guard)
   │                   │                      │
   ├───────────────────┴──→ 004-test ─→ 004-impl (version header)
   │                                            │
   ├──→ 005 (self-host guard)   needs 002, 004 ─┤
   └──→ 006 (mode-agnostic guard) needs 002,004 ┘

001 ─→ 010 (saveConfig 0o600 guard)

004-impl + 008-impl ─→ 011 (docs) ─────────────┐
                                               ├─→ 012 (final verification)
004,005,006,008,009,010 ───────────────────────┘
```

**Analysis:**
- No circular dependencies. Within each paired group the `-impl` depends only on its own `-test`; cross-feature edges reference group NNNs only, so no self-cycle exists.
- Foundation 001 and 002 are independent and can proceed in parallel; 003-test (pure policy test) is fully independent and can also start immediately.
- Three independent feature streams after foundation: version-check (003-test→003-impl→004-test→004-impl), auth (007-test→007-impl, 008-test→008-impl), and the invariant guards (005, 006, 009, 010).
- 008-impl depends on 007-impl because `login` extends the `AuthClient` actor created by the register impl (true technical prerequisite, shared type).
- 011 (docs) waits on the two behavioral impls (004-impl, 008-impl); 012 (verification) is the final fan-in.

---

## Execution Handoff

**Plan complete and saved to `docs/plans/2026-06-23-dual-mode-sync-plan/`. Load `superpowers:executing-plans` skill using the Skill tool — it orchestrates per-batch sub-agent coordinators through the full Phase 1-6 pipeline.**
