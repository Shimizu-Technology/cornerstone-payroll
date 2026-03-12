# Rollout Execution Pack — Cornerstone Payroll (CPR-72)
**QuickBooks → Cornerstone Payroll Parallel-Run Cutover**

> **What this is:** Operational docs for running real payroll in parallel with QuickBooks,
> validating accuracy cycle-by-cycle, and safely cutting over each client.

---

## Documents

| # | File | Purpose |
|---|------|---------|
| 01 | [01-PARALLEL-RUN-VALIDATION-TEMPLATE.md](01-PARALLEL-RUN-VALIDATION-TEMPLATE.md) | PASS/FAIL form — complete one per client per cycle |
| 02 | [02-MOSA-CYCLE-RUNBOOK.md](02-MOSA-CYCLE-RUNBOOK.md) | Step-by-step runbook for one MoSa pay cycle (import mode) |
| 03 | [03-CUTOVER-GATE-CRITERIA.md](03-CUTOVER-GATE-CRITERIA.md) | Strict go/no-go rules for each client's QB → CP cutover |
| 04 | [04-MULTI-CLIENT-SEQUENCING-PLAN.md](04-MULTI-CLIENT-SEQUENCING-PLAN.md) | Rollout order + gate tracker for all 5 clients |
| 05 | [05-ISSUE-REMEDIATION-LOG.md](05-ISSUE-REMEDIATION-LOG.md) | Issue log template + escalation rules |

---

## Evidence Folder Structure

Completed validation templates and report artifacts go here:

```
evidence/
├── ISSUE-LOG.md              ← live issue log (copy from template #05)
├── mosa/
│   └── YYYYMMDD-mosa-cycle-N.md
├── shimizu-technology/
│   └── YYYYMMDD-st-cycle-N.md
├── cornerstone-internal/
│   └── YYYYMMDD-ci-cycle-N.md
├── ddg/
│   └── YYYYMMDD-ddg-cycle-N.md
└── spr/
    └── YYYYMMDD-spr-cycle-N.md
```

---

## Quick Reference: Tolerance Table

| Field | Import Mode | Manual Mode |
|-------|------------|-------------|
| Employee count | Exact (0 tolerance) | Exact (0 tolerance) |
| Gross pay total | $0.00 | ≤$1.00/period |
| Net pay per employee | ≤$0.01 | ≤$0.01 |
| Net pay total | ≤$0.50/period | ≤$0.50/period |
| FIT/DRT withholding (per emp) | ≤$0.01 | ≤$0.01 |
| SS withholding (per emp) | ≤$0.01 | ≤$0.01 |
| Medicare withholding (per emp) | ≤$0.01 | ≤$0.01 |
| Tax totals (aggregate) | ≤$0.50/period | ≤$0.50/period |
| Employer SS total | ≤$0.50/period | ≤$0.50/period |
| Employer Medicare total | ≤$0.50/period | ≤$0.50/period |
| Check totals | Exact ($0.00) | Exact ($0.00) |

---

## Cutover Eligibility Summary

| Client | Min Cycles | Override Allowed? | Tips? | Priority |
|--------|-----------|-------------------|-------|----------|
| MoSa's Joint | 2 consecutive PASS | No | Yes (import) | 1st |
| Shimizu Technology | 2 consecutive PASS | Yes (Leon, 1-cycle) | No | 2nd |
| Cornerstone Internal | 2 consecutive PASS | Yes (Leon, 1-cycle) | No | 3rd |
| DDG | 2 consecutive PASS | Yes (Leon, 1-cycle) | No | 4th |
| SPR | 2 consecutive PASS | **No** | Yes (manual) | 5th |

---

_Pack version: CPR-72 · Created: 2026-03-12 · Owner: Leon Shimizu / Shimizu Technology_
