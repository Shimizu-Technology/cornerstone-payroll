# Cornerstone Payroll — Client-by-Client Rollout Plan (Week 1–4)

**Last updated:** 2026-03-10  
**Execution start (Week 1):** TBD — set before kickoff meeting  
**Owner:** Leon + Cornerstone Ops + Dev Team  
**Objective:** Safely transition payroll operations from QuickBooks to Cornerstone Payroll using a phased, low-risk rollout.

---

## 1) Rollout Strategy (Hybrid)

### A) Automated path (high complexity)
- **MoSa's Joint**
- Use MoSa import workflow (Revel PDF + Loan/Tip Excel) and existing validation/reporting pipeline.

### B) Manual-first path (small teams)
- **Shimizu Technology**
- **Cornerstone (internal team payroll)**
- **Duck Duck Goose (DDG)**
- **Spike Coffee Roasters (SPR)**
- Use manual payroll entry flow (hours/tips/deductions), with optional automation later.

### C) Deferred onboarding
- **AIRE Services**
- Start when first real payroll cycle details arrive.

### D) Operating mode definitions
- **Parallel mode:** Run payroll in both Cornerstone Payroll and QuickBooks for the same pay period.
  - **Authoritative output in parallel mode:** QuickBooks remains official for payout/filing until the client passes cutover gates.
  - **Exit criteria:** Client exits parallel mode only after **2 consecutive PASS cycles** (or 1 PASS cycle + explicit Leon override) and explicit Leon + Cornerstone Ops signoff.
- **Cornerstone-primary mode:** Cornerstone Payroll becomes the system of record; QuickBooks is fallback/read-only.

---

## 2) Current Capability Snapshot

### Ready now
- Company/client setup
- Employee setup (hourly/salary, pay frequency, pay rate, filing fields)
- Pay period creation
- Payroll item entry/edit
- Payroll calculation → approve → commit
- Tax summary/reporting endpoints
- MoSa import workflow (scoped to MoSa)

### In progress / partial
- 941-GU report service (CPR-59 in progress, PR #10 open)

### Not complete for full QB parity
- W-2GU generation/export
- 941-GU credits/deposit integration
- ACH/NACHA export
- Void/adjust/re-run workflow
- Final payroll register PDF/export package

---

## 3) Week-by-Week Execution Plan

### Week 1 — MoSa + ST pilot

#### MoSa (parallel confidence run)
- Run full MoSa cycle using import flow.
- Verify:
  - unmatched names = 0
  - parser outliers = 0
  - gross discrepancy = 0
- Ops signoff: Cornerstone confirms period output matches expected totals.

#### Shimizu Technology (manual-first pilot)
- Set up/verify client profile + employees.
- Run one complete payroll cycle manually.
- Verify tax and net pay accuracy against expected baseline.

**Gate to pass Week 1:**
- 2 successful payroll runs (MoSa + ST) with no blocking discrepancies.

---

### Week 2 — Cornerstone internal + DDG

#### Cornerstone internal
- Run payroll from current staff hours and salary setup.
- Validate approval/commit flow with internal reviewer.

#### DDG (3 employees: 2 hourly, 1 salary)
- Input hours from biweekly timesheet process.
- Validate mixed hourly/salary handling and totals.

**Gate to pass Week 2:**
- Cornerstone + DDG each complete one clean cycle.

---

### Week 3 — SPR + second-cycle regression checks

#### SPR (10–15 employees, tips expected)
- Start manual entry flow for first cycle.
- Validate tips handling and supervisor review process.

#### Regression pass
- Re-run MoSa + ST + Cornerstone + DDG for second cycle.
- Confirm no drift in calculations and no workflow friction regressions.

**Gate to pass Week 3:**
- 5 clients successfully processed in Cornerstone Payroll with repeatable operator flow.

---

### Week 4 — Cutover readiness + AIRE intake

#### Cutover review
- Final go/no-go for each active client based on prior gates.
- Move clients from parallel mode to Cornerstone-primary mode.

#### AIRE prep
- Gather first real payroll source format for AIRE.
- Decide manual-only vs automation profile work.

**Gate to pass Week 4:**
- Approved cutover list + client-by-client operating owners.

---

## 4) Per-Client Operating Checklist (each payroll cycle)

1. Confirm pay period dates + pay date
2. Confirm active employees + pay rates
3. Enter/import payroll inputs (hours, overtime, tips, loans/deductions)
4. Run calculate
5. Review exception flags / totals
6. Approve
7. Commit/finalize
8. Save report artifacts for audit
9. Log any discrepancies and root cause

---

## 5) Validation & Signoff Rules

### Quantitative thresholds (operator use)
- **Employee count:** exact match required (**0 tolerance**).
- **Gross total variance:**
  - **MoSa import cycles:** **$0.00 required** (after parser/unmatched checks).
  - **Manual-entry cycles:** up to **$1.00 absolute variance per pay period** (rounding/data-entry tolerance only).
- **Net pay variance:** up to **$0.01 per employee** (rounding tolerance only).
- **Tax total variance (withholding + SS + Medicare):** up to **$0.01 per employee** and **$0.50 per pay period aggregate**.
- Any variance above thresholds requires FAIL + remediation path.

A payroll cycle is **PASS** only if:
- Employee count is correct
- Gross/net totals are within thresholds above
- Tax totals are within thresholds above
- No unresolved import/parser exceptions (MoSa)
- Approval/commit flow completed without errors
- Reviewer signoff captured

A cycle is **FAIL** if:
- Missing employees or unmatched records unresolved
- Gross/net/tax variance exceeds thresholds above
- Approval/commit flow blocked

### FAIL-cycle remediation path (mandatory)
If a cycle is **FAIL**:
1. **Do not commit/finalize** that cycle in Cornerstone Payroll.
2. **Keep/revert to QuickBooks authoritative** for that client’s active pay period (parallel mode).
3. **Log failure in Plane** using PASS/FAIL template with root cause + impact.
4. **Open follow-up fix ticket** and assign owner + target date before next cycle.
5. **Do not advance rollout gate** for that client until a clean re-run is achieved.

### Post-commit error path (until void/adjust/re-run is implemented)
If an error is discovered **after PASS + commit**:
1. Escalate immediately to Leon + Dev Team.
2. Do not attempt ad-hoc in-system reprocessing for that committed cycle.
3. Open a P1 ticket before the next client pay date and document incident impact.
4. **If still in parallel mode:** revert to QuickBooks as source of record for correction payroll handling.
5. **If in Cornerstone-primary mode:** Leon + Dev Team define the correction path case-by-case and document decision in the P1 ticket.

---

## 6) Client Readiness Matrix

| Client | Size/Type | Input Mode | Current Readiness | Notes |
|---|---|---|---|---|
| MoSa's Joint | Large restaurant, tips, hourly+salary | Automated import | Ready now | Keep parallel confidence checks in early cycles |
| Shimizu Technology | 2 employees | Manual | Ready now | Great low-risk pilot |
| Cornerstone (internal) | ~3–4 employees | Manual (+ future Cornerstone Tax timesheet sync) | Ready now | Start in Week 2 |
| DDG | 3 employees (2 hourly, 1 salary) | Manual (timesheet) | Ready now | Straightforward mixed-type validation |
| SPR | 10–15 employees | Manual (email/timesheet source) | Ready with minor setup | Tips expected; validate tip handling in first cycle |
| AIRE | 10–15 (future) | TBD | Deferred | Decide after first real cycle |

---

## 7) Immediate Next Actions

1. Finish CPR-59 review/merge.
2. Run Week 1 pilots:
   - MoSa
   - Shimizu Technology
3. Capture results in Plane comments using PASS/FAIL template.
4. Open follow-up parity tickets for any discovered gaps.

---

## 8) PASS/FAIL Comment Template (for Plane)

```text
Cycle: <Client> <YYYY-MM-DD to YYYY-MM-DD>
Mode: Manual | Import
Result: PASS | FAIL

Checks:
- Employee count: PASS/FAIL
- Gross/net totals: PASS/FAIL
- Tax totals: PASS/FAIL
- Approval/commit flow: PASS/FAIL
- Exceptions resolved (import mode only — N/A for manual): PASS/FAIL/N/A
- Reviewer signoff: <Name> | Complete _(must be Complete for PASS; Pending only valid for FAIL/open remediation records)_

Notes:
- <key findings>
- <follow-up actions>
```
