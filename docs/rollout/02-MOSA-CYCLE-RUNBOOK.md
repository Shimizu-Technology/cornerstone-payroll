# MoSa Cycle Runbook — Step-by-Step (One Pay Cycle)
**Cornerstone Payroll · QuickBooks Cutover Pack (CPR-72)**

> **Scope:** This runbook covers one complete MoSa payroll cycle from source-file receipt
> through commit + signoff in Cornerstone Payroll, **running in parallel with QuickBooks**
> until MoSa passes cutover gates.
>
> **Authoritative output during parallel mode:** QuickBooks remains the payout/filing source
> until MoSa achieves 2 consecutive PASS cycles **and** receives explicit Leon + Ops signoff.

---

## Prerequisites (confirm before starting)

- [ ] You have access to the MoSa payroll email (via Gmail / `gog`)
- [ ] The API server is running and reachable (staging or production — confirm env)
- [ ] You are logged into Cornerstone Payroll as an admin for MoSa's Joint
- [ ] Last cycle's pay period is **committed** (or you have an explicit note if it's still open)
- [ ] `scripts/mosa_run.sh` is present and executable
- [ ] `data/mosa-2025/raw/` is writable

---

## Phase 1 — Source File Receipt & Validation
_Estimated time: 15–30 min_

### Step 1.1 — Download source files from email

```bash
cd <REPO_ROOT>
scripts/mosa_run.sh download
```

Expected output:
- `data/mosa-2025/raw/PP<NN>-revel.pdf` — Revel POS PDF
- `data/mosa-2025/raw/PP<NN>-loans-tips.xlsx` — Loan/tip Excel

> **If email not found:** Check subject line manually. Common issue: "September" mislabeled.
> `gog gmail search --query "MoSa payroll" --limit 5`

- [ ] PDF file downloaded: `PP__-revel.pdf`
- [ ] Excel file downloaded: `PP__-loans-tips.xlsx`

### Step 1.2 — Add pay period config

Open `scripts/mosa_pay_periods.rb` (or equivalent config) and add the new period:

```ruby
# Format: { id: "PP<NN>", start_date: "YYYY-MM-DD", end_date: "YYYY-MM-DD", pay_date: "YYYY-MM-DD" }
{ id: "PP<NN>", start_date: "____-__-__", end_date: "____-__-__", pay_date: "____-__-__" },
```

- [ ] Period config added with correct dates (verify against email / MoSa payroll calendar)

### Step 1.3 — Run validation

```bash
scripts/mosa_run.sh validate
```

Check the output for all three gates:

| Gate | Expected | Actual | PASS? |
|------|----------|--------|-------|
| Periods OK | N/N (all) | __ | |
| Unmatched names | 0 | __ | |
| Gross diff for new period | $0.00 | __ | |

> **If any gate fails → STOP. Do not proceed to import. See Section 8 (Troubleshooting).**

- [ ] `Periods OK: N/N`
- [ ] `Unmatched names: 0`
- [ ] `Gross diff: 0.0` for the new period

### Step 1.4 — Debug run (if outliers or mismatches exist)

```bash
DEBUG=1 bundle exec rails runner scripts/mosa_full_year_validation.rb
```

Identify the specific employee/row with the discrepancy and resolve before continuing.

---

## Phase 2 — Import into Cornerstone Payroll
_Estimated time: 5–10 min_

### Step 2.1 — Apply the new period to the database

```bash
MOSA_APPLY=1 scripts/mosa_run.sh apply PP<NN>
```

> Apply **one period at a time**. Do not bulk-apply multiple periods unless performing a historical backfill under Leon's direct supervision.

- [ ] Apply script completed without error
- [ ] Confirm in Rails console (or admin UI) that payroll items were created:

```bash
cd api
rails runner "pp = PayPeriod.find_by(start_date: 'YYYY-MM-DD'); puts pp.payroll_items.count"
```

Expected: matches MoSa employee count for this period.

### Step 2.2 — Verify pay period in admin UI

1. Log into Cornerstone Payroll → MoSa's Joint → Pay Periods
2. Find the new pay period — status should be `calculated` or `draft`
3. Confirm:
   - [ ] Correct start/end dates
   - [ ] Correct employee count (compare to QB)
   - [ ] No employees with $0.00 gross unexpectedly

---

## Phase 3 — Pre-Approval Validation
_Estimated time: 20–45 min_

### Step 3.1 — Pull QB totals for this period

From QuickBooks (Cornerstone Ops runs this side):
- Export payroll detail report for this period
- Record the following in the validation template:
  - Total employees paid
  - Total gross wages (regular + OT)
  - Total tips
  - Total loan deductions
  - Total DRT withholding
  - Total SS employee
  - Total Medicare employee
  - Total SS employer
  - Total Medicare employer
  - Total net pay

### Step 3.2 — Pull Cornerstone Payroll totals

From admin UI → Reports → Tax Summary / Payroll Register for this period.

Record same fields as above.

### Step 3.3 — Complete the PASS/FAIL validation template

Open: `docs/rollout/01-PARALLEL-RUN-VALIDATION-TEMPLATE.md`
Save a filled copy to: `docs/rollout/evidence/mosa/YYYYMMDD-mosa-cycle-<N>.md`

Work through **all 10 sections**:

- [ ] Section 1: Employee count ← compare to QB headcount
- [ ] Section 2: Gross pay breakdown ← every line vs QB
- [ ] Section 3: Employee tax withholdings (FIT/DRT, SS, Medicare) ← per employee
- [ ] Section 4: Employer taxes (SS + Medicare) ← compare to QB
- [ ] Section 5: Net pay ← per employee + total
- [ ] Section 6: Check totals (if printing checks this cycle)
- [ ] Section 7: Report artifacts generated
- [ ] Section 8: Import exceptions (unmatched names, outliers, gross_diff)
- [ ] Section 9: Workflow gate checks
- [ ] Section 10: Discrepancy notes (document every Δ > tolerance with root cause)

### Step 3.4 — Decision point

| Outcome | Action |
|---------|--------|
| **All sections PASS** | Proceed to Phase 4 (Approval) |
| **Any section FAIL** | STOP → go to Phase 7 (FAIL path) |

---

## Phase 4 — Approval
_Estimated time: 5 min_

### Step 4.1 — Review in UI

1. Open the pay period in the admin UI
2. Click through each employee row — spot-check at least 3 employees
3. Verify no red flags / exception markers on the payroll detail page

### Step 4.2 — Approve

1. Click **Approve** on the pay period
2. Confirm status changes to `approved`

- [ ] Pay period status: `approved`
- [ ] No errors during approval action

### Step 4.3 — Second-eyes check

Have a second person (Leon or Ops lead) review the approved pay period before commit.

- [ ] Second reviewer has confirmed totals match template

---

## Phase 5 — Commit & Post-Processing
_Estimated time: 10 min_

> **Reminder:** During parallel mode, this commit is for **Cornerstone Payroll records only**.
> QuickBooks remains the authoritative payout source until cutover is complete.

### Step 5.1 — Commit

1. Click **Commit** on the approved pay period
2. Confirm status changes to `committed`

- [ ] Pay period status: `committed`
- [ ] No errors during commit action

### Step 5.2 — Check number assignment (if printing checks)

1. Verify check numbers were assigned sequentially from last cycle's ending check number
2. No gaps, no duplicates
3. Print check register — spot-check 3 random checks

- [ ] Check numbers assigned: __ through __
- [ ] No gaps or duplicates: Yes / N/A

### Step 5.3 — Generate and save report artifacts

| Report | Location Saved | Notes |
|--------|---------------|-------|
| Payroll register | `docs/rollout/evidence/mosa/YYYYMMDD-register.pdf` | |
| Tax summary | `docs/rollout/evidence/mosa/YYYYMMDD-tax-summary.pdf` | |
| YTD summary | `docs/rollout/evidence/mosa/YYYYMMDD-ytd.pdf` | |

- [ ] All reports generated and saved to evidence folder

---

## Phase 6 — Cycle Signoff & Gate Tracking

### Step 6.1 — Complete signoff on validation template

Fill in the **Signoff** section of the completed validation template:
- Payroll operator name + date
- Reviewer (Leon / Ops lead) name + date
- Mark overall result: **PASS**

### Step 6.2 — Update gate tracker

Open: `docs/rollout/04-MULTI-CLIENT-SEQUENCING-PLAN.md`
Update MoSa's consecutive PASS count and cycle log.

### Step 6.3 — Log in Plane

Add a comment to the active Cornerstone Payroll Plane ticket with:

```text
Cycle: MoSa <YYYY-MM-DD to YYYY-MM-DD>
Mode: Import
Result: PASS

Checks:
- Employee count: PASS
- Gross/net totals: PASS
- Tax totals: PASS
- Approval/commit flow: PASS
- Exceptions resolved: PASS
- Reviewer signoff: <Name> | Complete

Notes:
- <key findings if any>
```

- [ ] Plane comment posted

### Step 6.4 — Assess cutover gate

| Status | Next Action |
|--------|-------------|
| Cycle 1 PASS | Continue parallel mode; schedule Cycle 2 |
| Cycle 2 PASS (consecutive) | MoSa eligible for cutover — review `03-CUTOVER-GATE-CRITERIA.md` |
| Any FAIL resets consecutive count | Restart count from 0 after remediation PASS |

---

## Phase 7 — FAIL Path (if any section fails)
_Follow this ONLY if the validation template yields any FAIL_

### Step 7.1 — Do not commit

- [ ] Pay period is **NOT committed** in Cornerstone Payroll
- [ ] QuickBooks remains authoritative for this pay period

### Step 7.2 — Document the failure

Fill in the Discrepancy Notes section of the validation template with:
- Every failing line item
- Δ values
- Initial hypothesis for root cause

### Step 7.3 — Open a remediation ticket in Plane

Title: `CPR-FAIL: MoSa PP<NN> <YYYY-MM-DD> — <short description>`
Priority: **Urgent**
Include:
- Cycle date
- Which sections failed
- All Δ values
- Owner + target fix date (must be before next pay period)

### Step 7.4 — Escalate

If the discrepancy involves:
- **Gross diff ≠ $0.00:** Escalate immediately to Leon (dev team) — likely parser issue
- **Tax mismatch > $1.00:** Escalate to Leon — likely calculator bug
- **Employee count mismatch:** Escalate to Cornerstone Ops — likely HR data issue

See `docs/rollout/05-ISSUE-REMEDIATION-LOG.md` for escalation matrix.

### Step 7.5 — Re-run after fix

After fix is deployed, re-run the **entire cycle runbook** from Phase 1.
The FAIL cycle does NOT count toward the 2-consecutive-PASS gate.

---

## Phase 8 — Troubleshooting Reference

### Gross diff ≠ $0.00

```bash
DEBUG=1 bundle exec rails runner scripts/mosa_full_year_validation.rb
```
- Check if PDF has new column layout (Revel update)
- Check if an employee has two rows (manager + server dual role)
- Compare individual employee records manually against PDF

### Unmatched employee names

```bash
bundle exec rails runner scripts/mosa_backfill_employees.rb --dry-run
```
- Review unmatched names
- Either add an alias or create the employee record
- Re-run validation after fix

### Gmail token expired

```bash
gog auth refresh --account <YOUR_GMAIL_ACCOUNT>
```

### Wrong environment (staging vs prod)

```bash
cd api && rails runner "puts Rails.env"
```
Must match intended target before running `MOSA_APPLY=1`.

### Check number sequence gap

Query the DB:
```bash
rails runner 'PayrollItem.where(company_id: MOSA_COMPANY_ID).order(:check_number).pluck(:check_number).each_cons(2).select { |a,b| b - a > 1 }.each { |a,b| puts "Gap: #{a} -> #{b}" }'
```

---

## Timing Reference (MoSa Biweekly Schedule)

| When | What |
|------|------|
| Payroll email arrives (Friday–Monday typically) | Run Phase 1 immediately |
| Same day or next business day | Complete Phases 2–3 (import + validation) |
| After validation PASS | Phase 4–5 (approve + commit) |
| Same day as commit | Phase 6 (signoff + Plane log) |
| After Cycle 2 PASS | Review cutover gate criteria |

---

_Runbook version: CPR-72 · Last updated: 2026-03-12_
