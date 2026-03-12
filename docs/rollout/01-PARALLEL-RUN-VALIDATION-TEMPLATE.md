# Parallel-Run Validation Template — PASS / FAIL
**Cornerstone Payroll · QuickBooks Cutover Pack (CPR-72)**

> **How to use:** Complete one copy of this form per client per pay cycle.
> Save as `docs/rollout/evidence/<CLIENT>/<YYYYMMDD>-<CLIENT>-cycle-<N>.md`.
> A cycle is PASS only when **every required row is PASS** and the signoff section is complete.

---

## Header

| Field | Value |
|-------|-------|
| Client | _(e.g. MoSa's Joint)_ |
| Pay Period | YYYY-MM-DD → YYYY-MM-DD |
| Pay Date | YYYY-MM-DD |
| Cycle # | _(sequential: 1, 2, 3 …)_ |
| Input Mode | `Import` / `Manual` |
| Reviewer | _(name)_ |
| Date Completed | YYYY-MM-DD |
| Overall Result | **PASS** / **FAIL** |

---

## Section 1 — Employee Count

| Check | QB / Expected | Cornerstone | Δ | Tolerance | Result |
|-------|--------------|-------------|---|-----------|--------|
| Total active employees paid this cycle | __ | __ | __ | **0** | PASS / FAIL |
| Employees on leave / zero-pay (excluded) | __ | __ | __ | **0** | PASS / FAIL |

> **FAIL trigger:** Any mismatch in employee count → stop, do not commit, escalate.

---

## Section 2 — Gross Pay

| Line Item | QB ($) | Cornerstone ($) | Δ ($) | Tolerance | Result |
|-----------|--------|-----------------|-------|-----------|--------|
| Total regular wages | __ | __ | __ | Import: $0.00 · Manual: ≤$1.00/period | PASS / FAIL |
| Total overtime wages | __ | __ | __ | Import: $0.00 · Manual: ≤$0.50/period | PASS / FAIL |
| Total tips | __ | __ | __ | Import: $0.00 · Manual: ≤$0.50/period | PASS / FAIL |
| Total loan deductions | __ | __ | __ | **$0.00** | PASS / FAIL |
| Total retirement deductions | __ | __ | __ | **$0.00** | PASS / FAIL |
| Total other deductions | __ | __ | __ | **$0.00** | PASS / FAIL |
| **GROSS PAY (total)** | **__** | **__** | **__** | Import: **$0.00** · Manual: **≤$1.00** | **PASS / FAIL** |

---

## Section 3 — Employee Tax Withholdings

_Complete per-employee table below. Aggregate tolerances: ≤$0.01/employee, ≤$0.50/period aggregate._

| Employee | QB FIT ($) | CP FIT ($) | Δ | QB SS ($) | CP SS ($) | Δ | QB Medicare ($) | CP Medicare ($) | Δ | Row Result |
|----------|-----------|-----------|---|-----------|-----------|---|-----------------|-----------------|---|------------|
| _(name)_ | __ | __ | __ | __ | __ | __ | __ | __ | __ | PASS / FAIL |
| … | | | | | | | | | | |
| **Totals** | **__** | **__** | **__** | **__** | **__** | **__** | **__** | **__** | **__** | **PASS / FAIL** |

**Tolerance (per employee):**
- Guam income tax (FIT/DRT withholding): ≤ $0.01
- Social Security employee (6.2% of gross, capped at current-year SSA wage base — verify annually): ≤ $0.01
- Medicare employee (1.45% of gross): ≤ $0.01

---

## Section 4 — Employer Taxes

| Tax Line | QB ($) | Cornerstone ($) | Δ ($) | Tolerance | Result |
|----------|--------|-----------------|-------|-----------|--------|
| Employer SS (6.2%) | __ | __ | __ | ≤ $0.01/employee, ≤$0.50/period | PASS / FAIL |
| Employer Medicare (1.45%) | __ | __ | __ | ≤ $0.01/employee, ≤$0.50/period | PASS / FAIL |
| **Total employer taxes** | **__** | **__** | **__** | **≤$1.00/period** | **PASS / FAIL** |

---

## Section 5 — Net Pay

| Check | QB ($) | Cornerstone ($) | Δ ($) | Tolerance | Result |
|-------|--------|-----------------|-------|-----------|--------|
| Per-employee net pay (list worst Δ) | __ | __ | __ | ≤ $0.01/employee | PASS / FAIL |
| **Total net pay (all employees)** | **__** | **__** | **__** | **≤$0.50/period** | **PASS / FAIL** |

---

## Section 6 — Check Totals (if checks were printed)

| Check | Expected | Actual | Δ | Result |
|-------|----------|--------|---|--------|
| Number of checks issued | __ | __ | __ | PASS / FAIL |
| Total check amount (sum of all net pay checks) | $__ | $__ | $__ | PASS / FAIL |
| Check number sequence (no gaps / duplicates) | __ | __ | __ | PASS / FAIL |

> If no checks printed this cycle: mark all N/A.

---

## Section 7 — Report Artifacts

| Report | Generated? | Matches QB? | Notes |
|--------|-----------|-------------|-------|
| Payroll register (all employees, this period) | Yes / No | Yes / No / N/A | |
| Tax summary (DRT withholding + SS + Medicare) | Yes / No | Yes / No / N/A | |
| YTD summary (cumulative through this period) | Yes / No | Yes / No / N/A | |
| 941-GU report data (quarterly, if end-of-quarter) | Yes / No / N/A | Yes / No / N/A | |
| Check register (if applicable) | Yes / No / N/A | Yes / No / N/A | |

---

## Section 8 — Import-Mode Exceptions (MoSa only; skip for manual-entry clients)

| Exception Check | Expected | Actual | Result |
|----------------|----------|--------|--------|
| Unmatched employee names | 0 | __ | PASS / FAIL |
| Parser outlier rows (>200 hours) | 0 | __ | PASS / FAIL |
| Gross diff per period (`gross_diff`) | $0.00 | __ | PASS / FAIL |
| Import script runtime | < 5 min | __ min | PASS / FAIL |

---

## Section 9 — Workflow Gate Checks

| Check | Result | Notes |
|-------|--------|-------|
| Pay period created with correct dates | PASS / FAIL | |
| All employees included (none inadvertently excluded) | PASS / FAIL | |
| Calculate ran without error | PASS / FAIL | |
| Exception flags reviewed and resolved | PASS / FAIL | |
| Approved in system | PASS / FAIL | |
| Committed in system _(only if all above PASS)_ | PASS / FAIL / HELD | |

> **If any above is FAIL:** do not commit. Log in issue/remediation log.

---

## Section 10 — Discrepancy Notes

> List every Δ > tolerance here, even if minor. Include root cause and resolution.

| # | Employee / Line | QB Value | CP Value | Δ | Root Cause | Resolution | Status |
|---|----------------|----------|----------|---|------------|------------|--------|
| 1 | | | | | | | |

---

## Signoff

> **Both signatures required for PASS.** A FAIL cycle cannot be signed off as PASS.

| Role | Name | Signature / Initials | Date |
|------|------|----------------------|------|
| Payroll Operator | | | |
| Reviewer (Leon / Cornerstone Ops lead) | | | |

**Cycle result confirmed:** ☐ PASS — safe to commit / advance gate  
&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;☐ FAIL — do not commit; open remediation ticket

---

## Quick Reference: Tolerance Table

| Field | Import Mode | Manual Mode |
|-------|------------|-------------|
| Employee count | Exact (0 tolerance) | Exact (0 tolerance) |
| Gross pay (total) | $0.00 | ≤ $1.00/period |
| Net pay (per employee) | ≤ $0.01 | ≤ $0.01 |
| Net pay (total) | ≤ $0.50/period | ≤ $0.50/period |
| FIT/DRT withholding (per employee) | ≤ $0.01 | ≤ $0.01 |
| SS withholding (per employee) | ≤ $0.01 | ≤ $0.01 |
| Medicare withholding (per employee) | ≤ $0.01 | ≤ $0.01 |
| Tax totals (aggregate) | ≤ $0.50/period | ≤ $0.50/period |
| Employer SS (total) | ≤ $0.50/period | ≤ $0.50/period |
| Employer Medicare (total) | ≤ $0.50/period | ≤ $0.50/period |
| Check totals | Exact ($0.00) | Exact ($0.00) |
| Unmatched names (import) | 0 | N/A |
| Parser outliers (import) | 0 | N/A |

---

_Template version: CPR-72 · Last updated: 2026-03-12_
