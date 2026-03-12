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
4. If any section fails, **STOP — do not proceed to Phase 4 — follow FAIL Path below**.
   Also log in:
   - `05-ISSUE-REMEDIATION-LOG.md`

## Phase 4 — Approve + Commit
1. Approve period after second-eyes check.
2. **Commit period.**

> **Parallel-mode reminder:** During parallel mode, this commit is for **Cornerstone Payroll records only**.
> QuickBooks remains the authoritative payout/filing source until this client meets all
> cutover gates in `03-CUTOVER-GATE-CRITERIA.md` and receives explicit Leon + Ops signoff.
> Do **not** distribute payments from Cornerstone Payroll until cutover is approved.

3. Generate evidence artifacts (register/tax summary/check outputs).

## Phase 5 — Signoff
1. Complete validation template signoff (operator + reviewer).
2. Update sequencing tracker:
   - `04-MULTI-CLIENT-SEQUENCING-PLAN.md`
3. Assess cutover gate status explicitly:
   - Cycle 1 PASS → continue parallel mode
   - Cycle 2 consecutive PASS → run full gate review in `03-CUTOVER-GATE-CRITERIA.md`
   - Any FAIL → reset consecutive PASS count to 0
4. Add a Plane ticket comment for this cycle summarizing PASS/FAIL, key deltas, and remediation (if any).
5. Save evidence using filename format:
   - `docs/rollout/evidence/<client>/YYYYMMDD-<client>-cycle-<N>.md`

## Hard STOP Conditions
- Headcount mismatch
- Gross pay mismatch beyond tolerance
- Net pay mismatch beyond tolerance
- Tax withholding mismatch beyond tolerance
- Any unresolved P1/P2 issue

### FAIL Path (when any Hard STOP triggers)
1. Do **not** approve/commit in Cornerstone Payroll.
2. Complete discrepancy notes in `01-PARALLEL-RUN-VALIDATION-TEMPLATE.md` for every failing line.
3. Open/update issue entry in `docs/rollout/evidence/ISSUE-LOG.md` and post Plane comment with severity + owner + ETA.
4. Escalate immediately based on severity rules in `05-ISSUE-REMEDIATION-LOG.md`.
5. Re-run from Phase 1 after fixes; FAIL cycles do not count toward consecutive-PASS gates.

## Notes for SPR (manual-entry + tips)
- Apply Section 2 tie-breaker rule from validation template.
- Explicitly review tips and gross-total tolerance before approval.
