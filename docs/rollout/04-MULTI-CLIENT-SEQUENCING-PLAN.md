# Multi-Client Sequencing Plan
**Cornerstone Payroll · QuickBooks Cutover Pack (CPR-72)**

> **Purpose:** Define the order, timing, and gate dependencies for rolling out Cornerstone Payroll
> across all five active clients, replacing QuickBooks as the payroll system of record.
>
> **Sequence rationale:**
> 1. **MoSa first** — largest client, highest complexity, automated import; longest parallel run needed
> 2. **Shimizu Technology second** — smallest team, lowest risk; ideal pilot for manual-entry flow
> 3. **Cornerstone internal third** — internal team = fastest issue detection + tightest feedback loop
> 4. **DDG fourth** — small, mixed hourly/salary; validates manual entry for small clients
> 5. **SPR last** — 10–15 employees + tips; needs prior validation experience before tackling complexity

---

## Master Timeline Overview

| Week | Primary Work | Clients in Parallel Mode | Target Gate |
|------|-------------|--------------------------|-------------|
| **Week 1** | MoSa Cycle 1 + ST Cycle 1 | MoSa, ST | Both complete ≥1 PASS cycle |
| **Week 2** | MoSa Cycle 2 + Cornerstone internal Cycle 1 + DDG Cycle 1 | MoSa, ST, CI, DDG | MoSa hits 2 consecutive PASS; ST eligible for cutover review |
| **Week 3** | SPR Cycle 1 + regression re-runs (all clients) | All 5 | SPR Cycle 1 PASS; 2nd PASS for CI + DDG |
| **Week 4** | Cutover decisions + AIRE intake | Cutting over clients | Approved cutover list |

> **Note:** "Week 1" starts on the agreed execution start date. Biweekly pay cycles may span multiple calendar weeks.
> Adjust the week numbers to match actual pay period dates — the sequence is what matters, not the calendar.

---

## Client Sequencing Details

### 1 — MoSa's Joint (First, Automated Import)

**Why first:** Largest client + most complexity = longest parallel run needed. Automated import means issues are systematic and fixable. Starting early gives maximum time.

**Pay frequency:** Biweekly

| Cycle | Target Period | Goal | Gate Achieved? | Notes |
|-------|-------------|------|----------------|-------|
| Cycle 1 (Parallel) | Week 1 | Validate import pipeline end-to-end against QB | ☐ PASS / ☐ FAIL | First live parallel run |
| Cycle 2 (Parallel) | Week 2–3 | 2nd consecutive PASS → cutover eligible | ☐ PASS / ☐ FAIL | If PASS: proceed to cutover gate review |
| Cycle 3+ | If cycles 1 or 2 fail | Remediation + re-run | | Reset consecutive count if any FAIL |
| **Cutover** | After Gate approval | Move to CP-primary | ☐ Approved | Requires 03-CUTOVER-GATE-CRITERIA.md Gate 1–5 |

**Responsible operator:** Cornerstone Ops (with Dev Team for import script issues)
**Escalation contact:** Leon (import/parser issues) → Cornerstone Ops lead (HR/data issues)

**MoSa-specific risks:**
- Revel PDF layout change (medium likelihood, high impact)
- New employee not in DB (medium likelihood, low impact)
- Dual-role employee (two rows in PDF) creating parser outlier

---

### 2 — Shimizu Technology (Second, Manual Entry)

**Why second:** 2-person team = minimal complexity. Perfect to validate the manual-entry workflow before more complex clients.

**Runbook:** `docs/rollout/06-MANUAL-ENTRY-CYCLE-RUNBOOK.md`

**Pay frequency:** Biweekly (or per Leon's schedule)

| Cycle | Target Period | Goal | Gate Achieved? | Notes |
|-------|-------------|------|----------------|-------|
| Cycle 1 (Parallel) | Week 1 | Validate manual entry flow against QB | ☐ PASS / ☐ FAIL | Low risk; should be clean |
| Cycle 2 or Override | Week 2 or after C1 PASS | 2nd PASS or Leon 1-cycle override | ☐ PASS / ☐ Override | Leon may use 1-cycle override given team size |
| **Cutover** | After Gate approval | Move to CP-primary | ☐ Approved | |

**Responsible operator:** Leon (owns the company)
**Escalation contact:** Leon

**Key validations for ST:**
- Both employees correct pay rates
- Correct pay type (salary vs hourly) per employee
- Filing status + allowances correct

---

### 3 — Cornerstone Internal (Third, Manual Entry)

**Why third:** Internal team = fastest feedback loop. Issues found here are caught before they affect external clients. Also validates the "small team + mixed pay types" pattern.

**Runbook:** `docs/rollout/06-MANUAL-ENTRY-CYCLE-RUNBOOK.md`

**Pay frequency:** Biweekly (same as QB schedule)

| Cycle | Target Period | Goal | Gate Achieved? | Notes |
|-------|-------------|------|----------------|-------|
| Cycle 1 (Parallel) | Week 2 | Validate internal payroll vs QB | ☐ PASS / ☐ FAIL | ~3–4 employees |
| Cycle 2 or Override | Week 3 or after C1 PASS | 2nd PASS or Leon 1-cycle override | ☐ PASS / ☐ Override | |
| **Cutover** | After Gate approval | Move to CP-primary | ☐ Approved | |

**Responsible operator:** Cornerstone Ops lead
**Escalation contact:** Leon

**Key validations for CI:**
- Salary employees: correct semi-monthly / biweekly gross
- Any manual bonuses or adjustments reflected correctly
- DRT withholding per allowances matches QB

---

### 4 — Duck Duck Goose (DDG) (Fourth, Manual Entry)

**Why fourth:** 3-employee mixed team (2 hourly, 1 salary) validates hourly+salary handling in the same period — a common pattern across future clients.

**Runbook:** `docs/rollout/06-MANUAL-ENTRY-CYCLE-RUNBOOK.md`

**Pay frequency:** Biweekly (timesheet source)

| Cycle | Target Period | Goal | Gate Achieved? | Notes |
|-------|-------------|------|----------------|-------|
| Cycle 1 (Parallel) | Week 2 | Validate hourly+salary mix, timesheet input | ☐ PASS / ☐ FAIL | |
| Cycle 2 or Override | Week 3 or after C1 PASS | 2nd PASS or Leon 1-cycle override | ☐ PASS / ☐ Override | |
| **Cutover** | After Gate approval | Move to CP-primary | ☐ Approved | |

**Responsible operator:** Cornerstone Ops
**Escalation contact:** Leon

**Key validations for DDG:**
- Hourly OT calculation correct (1.5×)
- Salary employee: correct gross regardless of hours field
- Both types pass tax calculations independently

---

### 5 — Spike Coffee Roasters (SPR) (Fifth, Manual Entry + Tips)

**Why last:** 10–15 employees + tips = highest complexity among manual-entry clients. Prior experience with MoSa (tips via import) and smaller clients informs how to handle this.

**Runbook:** `docs/rollout/06-MANUAL-ENTRY-CYCLE-RUNBOOK.md`

**Pay frequency:** Biweekly (email/timesheet source)

| Cycle | Target Period | Goal | Gate Achieved? | Notes |
|-------|-------------|------|----------------|-------|
| Cycle 1 (Parallel) | Week 3 | Validate tips handling + full headcount | ☐ PASS / ☐ FAIL | No override permitted; 2 cycles required |
| Cycle 2 (Parallel) | Week 4 or next period | 2nd consecutive PASS | ☐ PASS / ☐ FAIL | |
| **Cutover** | After Gate approval | Move to CP-primary | ☐ Approved | Requires full 2-cycle standard |

**Responsible operator:** Cornerstone Ops
**Escalation contact:** Leon

**Key validations for SPR:**
- Tips entered and flowing through to gross correctly
- SS/Medicare correct on tip income
- DRT withholding correct on tip income
- OT calculated correctly (if any hourly employees work OT)
- Headcount matches each cycle (10–15 employees — verify no one missed)

---

## Gate Dependency Map

```
Week 1:
  MoSa C1 ─────────────────────────────────────────┐
  ST C1 ─────────────────────┐                      │
                              ▼                      ▼
Week 2:                     ST Cutover?          MoSa C2 ─────┐
  CI C1 ─────────────┐                                         │
  DDG C1 ─────────────┐                                        │
                      │                                        ▼
Week 3:               │                            MoSa Cutover Gate
  SPR C1 ──────┐      │
               │      ▼
               │    CI C2 / DDG C2 → Cutover Gates
               ▼
Week 4:     SPR C2 → SPR Cutover Gate
  Final cutover decisions + AIRE intake
```

---

## Consecutive PASS Tracker (Live — Update Each Cycle)

| Client | Cycle 1 | Cycle 2 | Cycle 3 | Consecutive PASSes | Cutover Eligible? |
|--------|---------|---------|---------|-------------------|-------------------|
| MoSa | ☐ | ☐ | ☐ | 0 | No |
| Shimizu Tech | ☐ | ☐ | — | 0 | No |
| Cornerstone Internal | ☐ | ☐ | — | 0 | No |
| DDG | ☐ | ☐ | — | 0 | No |
| SPR | ☐ | ☐ | ☐ | 0 | No |

_Update this table after each cycle. ✅ = PASS, ❌ = FAIL_

---

## Parallel Mode Operating Rules (All Clients)

While any client is in parallel mode:

1. **QuickBooks is authoritative** for payout and filing
2. **Cornerstone Payroll runs the same period** for validation only
3. **No client funds flow** from CP (checks may be printed for testing but not distributed)
4. **Every cycle** requires a completed PASS/FAIL validation template
5. **Every FAIL** requires a remediation ticket before the next cycle
6. **Cutover requires explicit Gate review** (see `03-CUTOVER-GATE-CRITERIA.md`)

---

## Risk & Contingency

| Risk | Impact | Mitigation |
|------|--------|------------|
| MoSa has 2 consecutive FAILs | High — delays entire rollout | Escalate to P1; Dev Team prioritizes fix |
| QB becomes unavailable during parallel mode | High | Ensure QB access is maintained; don't let licenses lapse |
| ST/CI/DDG are tiny — QB numbers may be from memory, not printout | Medium | Require actual QB payroll detail report export for comparison |
| SPR tips vary wildly period-to-period | Medium | Accept variance in tip amounts (not a discrepancy if tips actually changed); only flag if the **same period** has a mismatch |
| New employee joins during parallel mode | Low | Add to both QB and CP before running the cycle; confirm counts match |
| Pay period dates differ between QB and CP | High | Confirm period start/end before every cycle; use QB calendar as reference |

---

## AIRE Services (Deferred)

AIRE is deferred until first real payroll cycle details arrive.

When ready:
- Determine input mode (manual vs automated)
- Assign a cycle start target week
- Insert into this sequencing plan after SPR cutover
- Follow the same gate criteria as other clients

---

_Document version: CPR-72 · Last updated: 2026-03-12_
