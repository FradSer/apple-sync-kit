# Design Evaluation — Dual-Mode Sync (Self-Host + Cloud)

**Mode:** design
**Design folder:** `docs/plans/2026-06-23-dual-mode-sync-design/`
**Checklist:** `docs/retros/checklists/design-v1.md` (v1)
**Artifacts read:** `_index.md`, `architecture.md`, `bdd-specs.md`, `best-practices.md` (all present)

## Checklist Results

| Item ID | Check | Result | Evidence |
|---|---|---|---|
| JUST-01 | Design must not self-declare NOT-JUSTIFIED | PASS | No deferral/not-justified marker anywhere in `_index.md`. |
| REQ-TRACE-01 | Every `REQ-NNN` in _index.md appears in a scenario | PASS | Design uses A1–A12 / B1–B7, not `REQ-NNN`; traceability satisfied: A1 → `bdd-specs.md:31-88`; A3/A7 byte-identical sync → `bdd-specs.md:90-111`; A4 → `:47-58,76-88`; A5 → `:53-58`; A6 → `:113-143`; self-host regression → `:8-29`; encryption invariant → `:145-166`; B1-B7 → `@worker` `:168-229`. |
| SCEN-CONC-01 | All Given clauses use specific data values | FAIL | `bdd-specs.md:154` and `:161` used the vague placeholder "valid". |
| ARCH-01 | No inner-to-outer layer dependencies | PASS | `AuthResult`/`SyncVersionPolicy` (Models, pure) carry no infra refs; `AuthClient` in Network; CLI does wiring only. Arrows run outer→inner→external. |
| RISK-02 | Each risk mitigation specifies a concrete action | PASS | Risk content is concrete (rollout ordering `architecture.md:182-187`; abuse controls `best-practices.md:63-69`; no-existence-leak `_index.md:88-90`; tenant isolation `_index.md:120-122`). |

## Rework Items (round 1)

| Item ID | File | Location | What failed | Corrective action |
|---|---|---|---|---|
| SCEN-CONC-01 | `bdd-specs.md` | line 154 | Given used vague "valid API token" | Replace with a concrete token value. |
| SCEN-CONC-01 | `bdd-specs.md` | line 161 | Given used vague "valid API token" | Replace with a concrete token value. |

## Verdict

**REWORK** — 1 FAIL: SCEN-CONC-01 (two `Given` clauses with the forbidden placeholder "valid"). All
other items PASS; the design is content-strong and this is a narrow mechanical fix. Resolved in round 2
by substituting concrete token values.

## Advisory (not a verdict factor)

REQ-TRACE-01 and RISK-02 anchor on `REQ-NNN` IDs and a heading literally named "Risks", neither of
which this design uses (it uses A/B requirement IDs and folds risk-handling into Rationale / Rollout /
Best-Practices). Both PASS under the literal check but are effectively no-ops against this artifact's
conventions. Candidate for a checklist retrospective: generalize the requirement-ID pattern (e.g.
`[A-Z]+-?[0-9]+`) and recognize risk content outside a "Risks" heading.
</content>
