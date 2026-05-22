# MoSa Loans and Import Workflow Plan

Date: 2026-05-20

## Why this exists

MoSa sends Cornerstone a payroll email each cycle with a Revel payroll PDF and a loan/tip workbook. The current system can import the PDF hours/gross pay and can import tips/loan deductions from the workbook, but loan details are currently flattened into one `loan_deduction` amount.

That is enough for basic paycheck math, but not enough for operational safety. Cornerstone needs to know whether a loan deduction is:

1. an open-ended recurring deduction that continues until someone removes it, or
2. an installment loan payment against a known balance that should stop automatically when paid off.

This matters because payroll staff need to prevent situations where a loan keeps deducting after it should be paid off, while still allowing real-world cases where Cornerstone only knows "deduct $50 per payroll until further notice."

## Business rules confirmed from Cornerstone workflow

- Loan deductions happen **after** taxable wages are calculated and after employee taxes are computed.
- Tips are taxable wages.
- Tips paid out in cash still need to be reported/taxed, then deducted from the paycheck because the cash was already paid.
- Reimbursements/pass-throughs/allotments/rent repayments are not automatically taxable wages; they need explicit classification.
- Quarterly reporting is based on **pay date/check date**, not pay-period end date.
- Payroll preview/review is a critical control point before checks are printed or payroll is committed.

## MoSa source files

MoSa’s payroll email normally includes:

- Email body notes, e.g. manual hour notes and expected total pay.
- Revel payroll PDF with hours/gross pay.
- Loan and Tip Excel workbook with tabs:
  - `TIPS - BOH`
  - `TIPS - FOH`
  - `LOANS (NO INSTALLMENTS)`
  - `INSTALLMENT LOANS`

## Loan modes we need to support

### 1. Recurring deduction / no-balance loan

Used when the client tells Cornerstone to deduct a recurring amount but no total loan balance is being tracked in the system.

Example: deduct `$50` every payroll until someone says to stop.

Behavior:

- No original loan amount required.
- Deducts after taxes.
- Does not auto-pay off.
- Continues until manually suspended/stopped/removed.
- Every payroll deduction should still be visible in payroll history/audit.

### 2. Installment loan / balance-tracked loan

Used when there is a known loan balance.

Example: original or remaining balance is `$275`; scheduled deduction is `$50`; final payroll should only deduct `$25` and then mark the loan paid off.

Behavior:

- Tracks beginning/current balance.
- Allows new additions to the balance.
- Deducts payments after taxes.
- Caps final payment to remaining balance.
- Marks paid off when balance reaches zero.
- Stops future deductions after payoff.
- Creates loan ledger transactions linked to payroll/pay period.

## Import interpretation

### `TIPS - BOH`

- Parse as BOH tips.
- Add to total taxable tips.
- Preserve BOH amount separately for review.

### `TIPS - FOH`

- Parse as FOH tips.
- Add to total taxable tips.
- Preserve FOH amount separately for review.

### `LOANS (NO INSTALLMENTS)`

- Treat as recurring/no-balance loan deduction input for that payroll.
- Add to paycheck loan deduction total.
- Preserve separately from installment loans.

### `INSTALLMENT LOANS`

- Treat as balance-tracked loan input.
- Parse beginning balance, new loan additions, payment this pay period, and estimated ending balance.
- Add only the payment amount to paycheck loan deduction total.
- Preserve all balance fields for reconciliation.

## Implementation plan

### PR 1 — Preserve MoSa import detail without changing payroll math

Goal: keep current payroll calculations working exactly as-is while making parsed import detail richer.

Scope:

- Update `PayrollImport::LoanTipExcelParser` to output:
  - `tips_boh`
  - `tips_foh`
  - `recurring_loan_deduction`
  - `installment_beginning_balance`
  - `installment_new_amount`
  - `installment_payment`
  - `installment_estimated_ending_balance`
  - existing `total_tips`, `tip_pool`, and `loan_deduction`
- Update import preview merging so duplicate/fuzzy-matched Excel rows retain the breakdown.
- Keep `loan_deduction = recurring_loan_deduction + installment_payment` for backwards compatibility.
- Add tests for MoSa workbook sheet structure.
- No payroll calculation behavior changes.

### PR 2 — Add explicit loan tracking modes

Goal: allow employee loan records to be either recurring/no-balance or installment/balance-tracked.

Scope:

- Add a tracking mode to `employee_loans`.
- Relax original/current balance requirements for recurring/no-balance loans.
- Update API/UI copy and validation.
- Make loan setup clear: recurring deduction vs installment loan.

### PR 3 — Commit-time loan ledger integration

Goal: make committed payroll update the appropriate loan history safely.

Scope:

- Link payroll loan deductions to active employee loan records when possible.
- For recurring/no-balance loans, record deduction history without reducing a balance.
- For installment loans, apply additions/payments, cap final payment, reduce balance, and mark paid off.
- Add warnings/errors for ambiguous matches or overpayments.
- Ensure rerunning/committing cannot double-record loan payments.

### PR 4 — MoSa import preview warnings and reconciliation

Goal: make payroll review catch issues before checks are printed.

Scope:

- Show loan import breakdown in preview.
- Flag imported loan rows without matching active loan setup.
- Flag installment beginning balance mismatches.
- Flag estimated ending balance mismatches.
- Flag final-payment caps.
- Capture/display source email notes and expected MoSa pay total.

## PPE 2026-05-16 reconciliation notes

Cornerstone's finalized payroll summary showed an important source-of-truth rule for MoSa imports:

- The Revel PDF is reliable for hours and employee presence/absence review.
- The Revel PDF gross pay should not be treated as authoritative because it may use stale/wrong rates.
- Employee master payroll rates are the wage authority for calculating hourly gross pay.
- The MoSa loan/tip workbook is reliable for tips, but loan deductions still need review against Cornerstone's final handling.

Open questions to confirm with Cornerstone/MoSa:

- Madela Severin: MoSa's workbook showed recurring loan `$454.00` plus installment payment `$75.00`, but Cornerstone's final payroll deducted only `$454.00`. Confirm whether Cornerstone accidentally missed the `$75.00` installment payment and whether a correction is needed.
- Sara/owner pass-throughs: Cornerstone's final payroll added items that were not in MoSa's loan/tip workbook, including bonus, allotment, rent, loan reimbursements, and auto-loan reimbursement. Confirm where these values came from and whether they are recurring every pay period or one-off for this cycle.
- Sara/owner adjustment classification: For each pass-through/adjustment, confirm whether it is taxable wages, non-taxable reimbursement/pass-through, pre-tax deduction, post-tax deduction, or memo/owner allocation.
- Brandon Mariano: Brandon is a 1099 contractor/manual check case, not included in Cornerstone's W-2 payroll check PDF. Confirm whether his imported MoSa loan deduction should still apply to his contractor check and whether contractor checks need a separate report/export from W-2 payroll.
- Accidental duplicate employees: Addison's duplicate contractor record was accidental and terminated only because there is no delete UI yet. Consider whether the app needs a guarded "delete accidental employee" admin action.

Recurring adjustment feature implemented in PR #90:

- Employee profiles can store recurring payroll adjustments with explicit classification:
  - taxable addition — adds taxable wages and increases payroll taxes.
  - non-taxable addition — adds to net pay without increasing taxable wages.
  - pre-tax deduction — reduces withholding wages before income-tax calculation and reduces net pay.
  - post-tax deduction — reduces net pay after taxes.
  - memo only — appears as an inactive/payroll-neutral note category for accounting context.
- These adjustments are separate from MoSa's tips/loan import.
- Legacy employee-level recurring custom earnings are migrated into payroll adjustments as `taxable_addition` entries, then cleared from the legacy field to avoid duplicate future payroll runs.
- New payroll items copy the employee defaults into the pay-period snapshot, so historical payroll does not change when future defaults are edited.
- The employee UI includes plain-English explanations and caution text to help payroll staff choose the correct treatment, and no longer shows the deprecated recurring custom earnings editor.

## Non-goals for PR 1

- No changes to tax calculations.
- No changes to loan balance mutation.
- No new payroll commit behavior.
- No database migration unless later PRs require it.
- No blocking import warnings yet.

PR 1 is intentionally a safe data-preservation step so later PRs can build loan tracking and reconciliation without changing paycheck math prematurely.
