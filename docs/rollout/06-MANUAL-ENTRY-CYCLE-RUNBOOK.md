# Manual-Entry Cycle Runbook (ST / Cornerstone Internal / DDG / SPR)

Use this runbook for clients that do not use the MoSa import flow.

## Scope
- Shimizu Technology
- Cornerstone Internal
- DDG
- SPR

## Phase 1 — Pre-flight
1. Confirm correct client + pay period dates.
2. Confirm employee roster is current (active/inactive, pay type, pay rates).
3. Confirm tax config year + filing setup is current.

## Phase 2 — Enter/Update Payroll Inputs
1. Enter hours/OT/bonuses/tips/adjustments per employee.
2. For salary employees, verify salary basis and expected gross.
3. Save changes and capture any validation warnings.

## Phase 3 — Calculate + Review
1. Run Calculate Payroll.
2. Compare totals against QuickBooks using:
   - `01-PARALLEL-RUN-VALIDATION-TEMPLATE.md`
3. Validate critical lines:
   - employee count
   - gross pay
   - FIT/SS/Medicare (employee + employer)
   - net pay
   - check totals (if checks used)
4. If any section fails, stop and log in:
   - `05-ISSUE-REMEDIATION-LOG.md`

## Phase 4 — Approve + Commit
1. Approve period after second-eyes check.
2. Commit period.
3. Generate evidence artifacts (register/tax summary/check outputs).

## Phase 5 — Signoff
1. Complete validation template signoff (operator + reviewer).
2. Update sequencing tracker:
   - `04-MULTI-CLIENT-SEQUENCING-PLAN.md`
3. Add a Plane ticket comment for this cycle summarizing PASS/FAIL, key deltas, and remediation (if any).
4. File evidence under `docs/rollout/evidence/<client>/`.

## Hard STOP Conditions
- Headcount mismatch
- Net pay mismatch beyond tolerance
- Tax withholding mismatch beyond tolerance
- Any unresolved P1/P2 issue

## Notes for SPR (manual-entry + tips)
- Apply Section 2 tie-breaker rule from validation template.
- Explicitly review tips and gross-total tolerance before approval.
