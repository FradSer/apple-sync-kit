# Design Checklist v2

- **Version:** v2
- **Mode:** design
- **Created:** 2026-06-23 (evolved from v1)

## Changelog (v1 → v2)

Inciting case: the 2026-06-23 dual-mode-sync design used `A#`/`B#` requirement IDs (not `REQ-NNN`) and
folded risk handling into Rationale/Rollout/Best-Practices (no literal "Risks" heading). Under v1 this
made **REQ-TRACE-01** and **RISK-02** pass *vacuously* — they matched nothing and provided zero
coverage. See `docs/retros/2026-06-23-checklist-v2-evolution.md`.

- **REQ-TRACE-01** generalized: the requirement-ID pattern is no longer hardcoded to `REQ-NNN`. IDs are
  now extracted from requirement **bullet lines** (`- **<ID>.**`) so any scheme (`A1`, `B7`, `REQ-001`)
  is matched, while avoiding false positives from inline tokens like `D1` or `AES-256`. Requirements
  explicitly tagged `(non-behavioral)` (docs, tooling, build, compile-time, meta) are exempt from
  needing a scenario.
- **RISK-02** broadened: risk mitigations are detected by `**Mitigation:**` markers **anywhere** in
  `_index.md`, not only under a heading literally named "Risks." The item now also FAILs when **no**
  risk-mitigation entry exists at all, so "no risks documented" can no longer pass vacuously.

## Purpose

Binary PASS/FAIL checklist for evaluating design artifacts. Each item produces a deterministic or
anchored result: two independent evaluators given the same artifacts should produce the same PASS/FAIL
outcome. Every FAIL must include file-referenced evidence and a specific rework action.

## Artifacts Under Evaluation

- `_index.md` -- plan overview, requirements, risks
- `bdd-specs.md` -- Gherkin scenarios
- `architecture.md` -- system architecture and layer descriptions
- `best-practices.md` -- coding and design standards (when present)

---

## Checklist Items

### JUST-01 -- Design must not self-declare NOT-JUSTIFIED

**Description:** A design folder whose `_index.md` carries an explicit "not yet justified" / "do not
implement" status declared by the maintainer or a prior brainstorming sub-agent must not pass
evaluation. The design's own §0-style status is dispositive — content-quality items below cannot
override it.

**Check method:**
```bash
grep -nE "STATUS:.*NOT.JUSTIFIED|DESIGN-NOT-YET-JUSTIFIED|DESIGN-CONSIDERED-DEFERRED|DO NOT IMPLEMENT" _index.md
```
Any match is a FAIL. Zero matches is PASS.

**Evidence format:** `_index.md:{line} -- "{matched line text}"`

**Rework format:** Either (a) remove the NOT-JUSTIFIED status from `_index.md` after addressing the
underlying activation gate, or (b) move the design folder to
`docs/retros/<date>-<topic>-considered-deferred.md` (single-file reject form).

**Verdict precedence:** A JUST-01 FAIL produces REWORK regardless of how content-quality items resolve.

`# Type: computational` -- grep against fixed-phrase list produces deterministic match.

---

### REQ-TRACE-01 -- Every behavioral requirement ID in _index.md appears in at least one scenario in bdd-specs.md

**Description:** Each behavioral requirement identifier in the Requirements section of `_index.md` must
be referenced by at least one scenario (or scenario `**Covers:**` tag) in `bdd-specs.md`. Requirement
IDs are matched on requirement **bullet lines** of the form `- **<ID>.**`, supporting any project ID
scheme (`A1`, `B7`, `REQ-001` — pattern `[A-Z]+-?[0-9]+`). Anchoring to the leading bullet token avoids
false positives from inline tokens such as `D1` or `AES-256`. Requirements explicitly tagged
`(non-behavioral)` on the bullet line (docs, tooling, build, compile-time, meta) are **exempt**.

**Check method:**
```bash
grep -E "^- \*\*[A-Z]+-?[0-9]+\.\*\*" _index.md \
  | grep -v "(non-behavioral)" \
  | grep -oE "^- \*\*[A-Z]+-?[0-9]+\." \
  | grep -oE "[A-Z]+-?[0-9]+" \
  | sort -u \
  | while read -r id; do
      grep -q "$id" bdd-specs.md || echo "FAIL: $id absent from bdd-specs.md"
    done
```
Any "FAIL" output line means REQ-TRACE-01 is FAIL. Empty output means PASS.

**Evidence format:** `requirement ID + absence note`

**Rework format:** "Add {ID} to a scenario `**Covers:**` tag or create a new scenario for {ID}; or, if
{ID} is genuinely non-behavioral, tag it `(non-behavioral)` on its bullet line in `_index.md`."

**Result:** PASS if every behavioral requirement ID appears in `bdd-specs.md`. FAIL otherwise.

`# Type: computational` -- anchored grep extraction + per-ID presence check is deterministic.

---

### SCEN-CONC-01 -- All Given clauses use specific data values

**Description:** Every `Given` clause in `bdd-specs.md` must use concrete, specific data values. Vague
placeholders such as "some", "valid", "appropriate", or "relevant" are not permitted.

**Check method:**
```bash
grep -n "Given " bdd-specs.md | grep -iE "\bsome\b|\bvalid\b|\bappropriate\b|\brelevant\b"
```
Any match is FAIL. Zero matches is PASS.

**Evidence format:** `bdd-specs.md:{line} -- "{clause text}"`

**Rework format:** "Replace '{vague phrase}' with concrete value at bdd-specs.md:{line}"

**Result:** PASS if zero matches. FAIL on any match.

`# Type: computational` -- grep against vague-word list produces deterministic match.

---

### ARCH-01 -- No inner-to-outer layer dependencies described

**Description:** `architecture.md` (or the Detailed Design section in `_index.md`) must not describe any
dependency, import, or reference from an inner architectural layer (Domain, Application) to an outer
layer (Infrastructure, Presentation/CLI).

**Check method:** Scan `architecture.md` for arrows or prose stating an inner layer imports from an
outer layer. Patterns: `domain.*infrastructure`, `application.*infrastructure`,
`domain.*presentation`. Confirm matches describe an actual dependency direction (not a prohibition such
as "domain must NOT import infrastructure").

**Evidence format:** `{file}:{line} -- "{dependency description}"`

**Rework format:** "Invert dependency at {file}:{line}; define interface in inner layer."

**Result:** PASS if no inner-to-outer dependency is described. FAIL on any.

`# Type: inferential` -- grep narrows candidates; evaluator confirms direction vs. prohibition.

---

### RISK-02 -- At least one risk is documented and every mitigation specifies a concrete action

**Description:** `_index.md` must document at least one risk with a mitigation, and every mitigation
must specify a concrete, actionable measure. Risk mitigations are detected by `**Mitigation:**` markers
**anywhere** in `_index.md` — they need not live under a heading literally named "Risks." Vague verbs
such as "monitor", "handle", "manage", "address", "deal with", "look into" indicate a non-concrete
mitigation when used as the sole action.

**Check method:**
```bash
# 1. There must be at least one mitigation entry.
grep -qE "\*\*Mitigation" _index.md || echo "FAIL: no risk mitigation entries in _index.md"
# 2. No mitigation may rely on a vague verb as its sole action.
grep -nE "\*\*Mitigation" _index.md | grep -iE "\bmonitor\b|\bhandle\b|\bmanage\b|\baddress\b|\bdeal with\b|\blook into\b"
```
Either a step-1 FAIL line or any step-2 match (confirmed as the primary action) means RISK-02 is FAIL.

**Evidence format:** `_index.md -- risk "{title}" mitigation "{text}"`

**Rework format:** "Add a `**Risk:** … **Mitigation:** …` entry, or replace the vague mitigation with a
concrete action (e.g., specific alert thresholds, retry policy, circuit breaker)."

**Result:** PASS if at least one mitigation exists and each describes a concrete action. FAIL otherwise.

`# Type: inferential` -- presence + vague-verb match is computational; primary-vs-supplement distinction is judgment.

---

## Evaluation Protocol

1. Run each check method against the design artifacts in the plan folder.
2. Record PASS or FAIL for each item.
3. For each FAIL, capture evidence in the specified format and produce a rework item with file, line,
   and corrective instruction.
4. Verdict: all items PASS = **PASS**. Any item FAIL = **REWORK** with itemized rework list. JUST-01
   has verdict precedence: a JUST-01 FAIL produces REWORK regardless of how the content-quality items
   resolve.
</content>
