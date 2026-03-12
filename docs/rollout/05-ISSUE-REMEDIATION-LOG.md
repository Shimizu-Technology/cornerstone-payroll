# Issue & Remediation Log — Template & Escalation Rules
**Cornerstone Payroll · QuickBooks Cutover Pack (CPR-72)**

> **Purpose:** Central log for all discrepancies, failures, and incidents discovered during the
> parallel-run rollout. Every FAIL cycle and every post-commit error must have an entry here.
>
> **Location for live log:** Copy this template to `docs/rollout/evidence/ISSUE-LOG.md`
> and update it in-place throughout the rollout.

---

## How to Use This Log

1. **Open an entry immediately** when a FAIL is declared or a post-commit error is discovered
2. Fill in as much as known at time of opening — incomplete is fine, blank is not
3. **Update the entry** as root cause is identified and fix is applied
4. **Close the entry** (Status → Resolved) only after a clean follow-up cycle confirms the fix
5. Link the Plane ticket in every entry

---

## Issue Severity Levels

| Level | Name | Criteria | Response Time |
|-------|------|----------|---------------|
| **P1** | Critical | Post-commit error discovered; employee underpaid/overpaid; tax filing at risk; system blocks payroll | **Immediately** — stop everything, escalate now |
| **P2** | High | Cycle FAIL with financial discrepancy (gross/net/tax outside tolerance); employee count mismatch | **Same business day** |
| **P3** | Medium | Cycle FAIL with non-financial issue (workflow error, report not generating, import timeout) | **Within 2 business days** |
| **P4** | Low | Minor discrepancy within tolerance but worth investigating; UI annoyance; documentation gap | **Next sprint / backlog** |

---

## Escalation Matrix

| Situation | First Contact | Second Contact | Third Contact |
|-----------|--------------|----------------|---------------|
| Import parser failure (MoSa) | Developer on-call (Leon) | — | — |
| Gross pay mismatch > $1.00 | Payroll Operator → Leon | Cornerstone Ops Lead | — |
| Employee count mismatch | Cornerstone Ops Lead | Leon | — |
| Tax withholding mismatch > $1.00 | Leon (dev) | Cornerstone Ops Lead | External CPA (if filing risk) |
| Post-commit error (any amount) | **Leon immediately** | Cornerstone Ops Lead | External CPA / DRT contact if tax affected |
| System outage blocking payroll | Leon → Dev Team | Cornerstone Ops (manual QB fallback) | — |
| Check printing failure | Cornerstone Ops | Leon | — |
| QuickBooks access lost during parallel | Cornerstone Ops (find backup) | Leon | — |

### Escalation SLAs

| Severity | Owner notified within | Resolution target |
|----------|-----------------------|-------------------|
| P1 | **15 minutes** | Before next pay date or same day |
| P2 | **2 hours** | Before next cycle run |
| P3 | **24 hours** | Within 3 business days |
| P4 | **1 week** | Next sprint |

---

## Issue Log Entry Template

Copy one block per issue.

```markdown
---
## Issue #<N> — <Short Title>

| Field | Value |
|-------|-------|
| Issue # | <N> |
| Opened | YYYY-MM-DD HH:MM ChST |
| Opened by | <Name> |
| Client | <Client name> |
| Cycle affected | <Pay period date range> |
| Severity | P1 / P2 / P3 / P4 |
| Status | Open / In Progress / Resolved / Won't Fix |
| Plane ticket | <URL or ticket ID> |
| Assigned to | <Name> |
| Target resolution | YYYY-MM-DD |
| Resolved | YYYY-MM-DD (or blank if open) |

### Description

<What happened? What was the operator doing when the issue was discovered?>

### Impact

- **Employees affected:** <count or "all">
- **Dollar impact:** $<amount> (gross / net / tax — specify)
- **Payroll committed?** Yes / No
- **QB authoritative?** Yes (parallel mode) / No (CP-primary)
- **Client payment at risk?** Yes / No

### Numbers

| Field | QB ($) | Cornerstone ($) | Δ ($) | Tolerance |
|-------|--------|-----------------|-------|-----------|
| <line item> | | | | |

### Root Cause

<Fill in when identified. Include: what system component caused it, why it happened, how long it may have been present.>

### Remediation Steps

- [ ] Step 1
- [ ] Step 2
- [ ] Step 3 — verify fix in clean follow-up cycle

### Resolution Notes

<How was it fixed? Was a code change deployed? Was employee data corrected? Was QB used as fallback?>

### Verification

| Verification step | Result | Date |
|-------------------|--------|------|
| Follow-up cycle run for this client | PASS / FAIL | |
| Plane ticket closed | Yes / No | |
| This log entry marked Resolved | Yes / No | |

---
```

---

## Live Issue Log

> Replace this section with actual entries as issues arise.
> Keep this file in `docs/rollout/evidence/ISSUE-LOG.md`.

_(No issues logged yet — rollout has not started)_

---

## Post-Commit Error Procedure (P1 — Detailed)

If an error is discovered **after a cycle is committed** in Cornerstone Payroll:

### Immediate actions (within 15 minutes)

1. **Stop all payroll processing** for the affected client
2. **Notify Leon immediately** (text/call — do not wait for async channel)
3. **Do not attempt in-system correction** without Leon's explicit instruction
4. **Open a P1 issue entry** in this log with all known details

### Within 1 hour

5. **Quantify the impact:**
   - Which employees are affected?
   - Is the error in gross, net, tax, or all?
   - What is the total dollar discrepancy?
   - Have checks been printed / distributed?

6. **Determine QB status:**
   - If still in **parallel mode:** QB is authoritative → QB correction handles the pay period
   - If in **Cornerstone-primary mode:** Leon + Dev Team define the correction path case-by-case

7. **Document the decision** in the Plane P1 ticket before the next client pay date

### Before next pay date

8. **Fix must be deployed or manual correction path defined** before next cycle
9. **Affected employees** must be made whole (correct payment issued via whatever method Leon approves)
10. **DRT / IRS notification** — if withholding was incorrect, consult external CPA on whether an amended filing is required

---

## Rollout Closure Checklist

When all 5 clients are in Cornerstone-Primary Mode:

- [ ] All open issues are Resolved or Won't Fix (with justification)
- [ ] All P1 and P2 issues have post-mortems documented
- [ ] Validation templates filed in `docs/rollout/evidence/<CLIENT>/`
- [ ] Gate criteria records filled in `03-CUTOVER-GATE-CRITERIA.md`
- [ ] Multi-client sequencing plan updated with final dates
- [ ] AIRE intake scheduled (if ready)
- [ ] This log archived to `docs/rollout/evidence/ISSUE-LOG-FINAL.md`
- [ ] Leon signs off on rollout completion

---

## Common Remediation Patterns

| Issue Type | Typical Root Cause | Typical Fix |
|------------|--------------------|-------------|
| Gross diff ≠ $0 (MoSa) | PDF column shift or dual-role row | Fix parser; re-apply period |
| Unmatched employee | Name in PDF doesn't match DB | Add alias or correct employee record |
| Tax mismatch > $0.01 | Calculator bug or allowances not wired | Code fix; re-calculate; do not commit until clean |
| Employee count mismatch | Employee active in QB but inactive in CP (or vice versa) | Sync employee status; re-run |
| Net pay rounding off by $0.01 | Floating point in deduction ordering | Acceptable if within tolerance; document if > $0.01 |
| Check number gap | Prior void not handled in sequence | Assign gap numbers to void stubs; re-verify register |
| Salary employee wrong gross | Pay rate stored wrong or employment type wrong | Correct in employee master; re-calculate |
| OT calculated wrong | Hours entered in wrong field (regular vs OT) | Correct hours; re-calculate |

---

_Document version: CPR-72 · Last updated: 2026-03-12_
