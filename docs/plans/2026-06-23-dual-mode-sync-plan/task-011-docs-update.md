# Task 011: Docs — AuthClient, Version Header, Mode-Agnostic Framing

**depends-on**: task-004-version-header-impl, task-008-auth-login-impl

## Description

Satisfy requirement A11: update the repo docs to describe the optional `AuthClient`, the new `X-AppleSyncKit-Version` request header + `SyncVersionPolicy`, and the self-host-vs-cloud framing, making explicit that the kit is mode-agnostic (no `tenant`/`mode` concept in the kit). Update both the English and Chinese READMEs and `CLAUDE.md`. Document the per-device encryption-key step so cloud users do not expect content to "just work" without exporting the key (design Risks: Key-UX bottleneck).

This is a documentation task — no code changes, no test pair.

## Execution Context

**Task Number**: 011 of 012
**Phase**: Documentation
**Prerequisites**: Behavioral impls landed (task 004 impl version header, task 008 impl `AuthClient.login` complete).

## BDD Scenario

Documentation supports, but does not itself test, the cloud-onboarding scenarios. Representative:

```gherkin
Scenario: A new logged-in device without the key cannot read content
  Given a new device holding apiToken "tok_live_abc123" from a prior cloud login
  And the device does not have the encryption key
  When it pulls records
  Then it receives only ciphertext
  And it cannot decrypt any record until the key is provided
```

**Spec Source**: `../2026-06-23-dual-mode-sync-design/bdd-specs.md` (for reference)

## Files to Modify/Create

- Modify: `README.md`
- Modify: `README.zh-CN.md` (keep in sync with the English changes)
- Modify: `CLAUDE.md`

## Steps

### Step 1: Confirm which docs exist
- Verify `README.md`, `README.zh-CN.md`, and `CLAUDE.md` are present; if a Chinese README is absent, note it and update only the files that exist.

### Step 2: Document the new surface
- `AuthClient`: optional `actor`; `register`/`login` returning `AuthResult`; HTTPS-only; self-host users never instantiate it; the returned token flows into the existing `SyncConfig.apiToken` and is persisted via `ConfigStore.saveConfig`.
- Version header: kit sends `X-AppleSyncKit-Version` on every request; mismatches warn once, non-fatally; never block sync.
- Mode-agnostic framing: the kit owns no `tenant`/`mode` concept; self-host vs cloud is a Worker deployment property; the sync wire path is byte-identical in both modes.
- Encryption-key step: every device must generate and export the base64 key (`openssl rand -base64 32`); logging in does NOT provision the key; a logged-in device without the key syncs ciphertext but cannot decrypt.

### Step 3: Keep CLAUDE.md architecture notes consistent
- Add the `AuthClient` actor and `SyncVersionPolicy` to the architecture/invariants section alongside `D1SyncClient`/`EncryptionService`, preserving the existing terse style and the canonical vocabulary from the design glossary.

## Verification Commands

```bash
swift format lint --strict --recursive Sources Tests   # docs change must not break lint of code
git diff --stat
```

## Success Criteria

- README (EN + ZH if present) and CLAUDE.md describe `AuthClient`, the version header, mode-agnostic framing, and the per-device key step.
- No `tenant`/`mode` is described as a kit code concept.
- No emojis introduced; vocabulary matches the design glossary ("API token", "self-host mode", "cloud mode", "Worker").
