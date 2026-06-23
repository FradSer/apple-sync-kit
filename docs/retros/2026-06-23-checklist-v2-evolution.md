# Retro — Design checklist v1 → v2 (vacuous-pass items)

**Date:** 2026-06-23
**Trigger:** round-2 evaluation of the dual-mode-sync design
(`docs/plans/2026-06-23-dual-mode-sync-design/`).

## What happened

The dual-mode-sync design passed the v1 design checklist (round 2, 0 FAIL). But the evaluator's own
advisory flagged that two of the five checklist items had passed **vacuously** — they matched nothing
in the artifact and therefore provided zero coverage:

- **REQ-TRACE-01** keyed on the literal `REQ-NNN` ID pattern. This design uses `A1`–`A12` / `B1`–`B7`
  identifiers, so `grep -oE "REQ-[0-9]+"` returned nothing and the traceability loop emitted no FAIL
  lines — a pass on an empty set.
- **RISK-02** scoped to a section literally named "Risks" and grepped for `mitigation` lines. This
  design folded risk handling into Rationale / Rollout / Best-Practices with no "Risks" heading, so
  there were no mitigation lines to check — again a pass on an empty set.

Neither was a content problem; both were checklist-coverage gaps. A design could omit traceability and
risk analysis entirely and still pass.

## Root cause

The v1 items were written against one specific convention (`REQ-NNN` IDs, a "Risks" heading) rather
than against the *intent* (every behavioral requirement is traceable; risks have concrete mitigations).
When a design used a different-but-valid convention, the checks silently became no-ops instead of
failing or adapting.

This is the same class of issue recorded in `2026-05-09-v3-considered-deferred.md`: a check that looks
green while measuring nothing.

## Changes (v2)

`docs/retros/checklists/design-v2.md`:

- **REQ-TRACE-01** now extracts IDs from requirement **bullet lines** (`- **<ID>.**`, pattern
  `[A-Z]+-?[0-9]+`), so any ID scheme is covered, while anchoring to the leading bullet token to avoid
  false positives from inline tokens like `D1` or `AES-256`. Requirements tagged `(non-behavioral)` are
  exempt (docs, tooling, build, compile-time, meta).
- **RISK-02** now detects `**Mitigation:**` markers anywhere in `_index.md` (no "Risks" heading
  required) and FAILs when *no* mitigation entry exists at all — closing the "no risks documented"
  vacuous pass.

Companion design edits (so the now-live checks have something real to measure):

- `_index.md` gained a `## Risks` section with six `**Risk:** … **Mitigation:** …` entries (concrete
  mitigations), and the non-behavioral requirements (A8–A12, B5, B7) were tagged `(non-behavioral)`.
- `bdd-specs.md` gained `**Covers:**` tags on each feature mapping it to the behavioral requirement IDs
  it exercises (A1–A7, B1–B4, B6).

## Lesson

Write checklist checks against the *intent* with a tolerant anchor (bullet-line IDs, marker-based risk
detection), and make "absent" a FAIL rather than a silent pass. A check that cannot fail is not a
check.
</content>
