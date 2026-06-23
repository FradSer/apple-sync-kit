# Task 012: Final Verification — Build, Test, Lint

**depends-on**: task-004-version-header-impl, task-005-selfhost-regression-test, task-006-mode-agnostic-test, task-008-auth-login-impl, task-009-e2e-cloud-test, task-010-saveconfig-roundtrip-test, task-011-docs-update

## Description

Final gate for requirements A9, A10, A12: the whole kit builds under Swift 6 strict concurrency, the full XCTest suite passes (new tests + existing tests unmodified), and `swift format lint --strict` is clean (the one expected `AvoidRetroactiveConformances` warning on `Connection+Sendable.swift` is the known, intentional exception per CLAUDE.md — do not "fix" it). Confirm no new dependency was added.

This is a verification task — it runs commands and asserts the suite is green; it makes no behavioral change beyond formatting fixups if the linter flags new files.

## Execution Context

**Task Number**: 012 of 012
**Phase**: Testing / Verification
**Prerequisites**: All implementation, guard, and docs tasks complete.

## BDD Scenario

This task verifies the union of all kit-scoped scenarios. Representative end-to-end check:

```gherkin
Scenario Outline: Sync behaves identically for any token source
  Given a SyncConfig whose API token was obtained via <source>
  When I run push, pull, and delete
  Then the requests carry the same Authorization bearer header shape
  And the same /api/v1/<entity> routes are used
  And no request differs based on how the token was obtained
```

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- None expected (formatting-only edits to new files if the linter flags them).

## Steps

### Step 1: Build
- `swift build` succeeds with no warnings introduced by the new code.

### Step 2: Full test suite
- `swift test` — all tests pass, including the new suites: `SyncVersionPolicyTests`, `D1SyncClientHeadersTests`, `SelfHostRegressionTests`, `ModeAgnosticSyncTests`, `AuthClientRegisterTests`, `AuthClientLoginTests`, `CloudEncryptionInvariantTests`, `CloudTokenPersistenceTests`, plus the pre-existing `ConfigStoreTests`, `EncryptionServiceTests`, `SyncModelsTests` (unmodified).

### Step 3: Format / lint
- `swift format --in-place --recursive Sources Tests` then `swift format lint --strict --recursive Sources Tests`.
- The only acceptable lint warning is `AvoidRetroactiveConformances` on `SQLite/Connection+Sendable.swift` (pre-existing, intentional). Any other strict-lint failure must be fixed.

### Step 4: Dependency check
- Confirm `Package.swift` / `Package.resolved` gained no new dependency (AsyncHTTPClient was already present).

## Verification Commands

```bash
swift build
swift test
swift format --in-place --recursive Sources Tests
swift format lint --strict --recursive Sources Tests
git diff --stat Package.swift Package.resolved
```

## Success Criteria

- `swift build` and `swift test` both green.
- `swift format lint --strict` clean except the documented `Connection+Sendable.swift` exception.
- No new dependency in the manifest.
- `SyncConfig` is unchanged (no `mode`/`tenant`/`email` field); zero `tenant`/`mode`/`cloud`/`self-host` code identifiers in the kit's API surface.
