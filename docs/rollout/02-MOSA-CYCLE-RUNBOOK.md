# MoSa payroll cycle runbook

This is Cornerstone's current operator procedure for one MoSa payroll cycle. It uses the Cornerstone Payroll interface. Legacy Gmail-download, employee-backfill, and database-apply scripts are not part of the live workflow.

During the required parallel cycles, QuickBooks remains the payout and filing source. Cornerstone records a comparison run only. Do not distribute a payment from Cornerstone until the cutover record is signed.

## Before opening the cycle

Confirm all of the following:

- you are signed into Cornerstone Payroll with access to the clean, intended MoSa company;
- the pay-period dates and pay date match MoSa's instructions;
- the preceding period has no unresolved correction or blocking issue;
- the current Revel payroll PDF is available;
- the Cornerstone payroll-changes workbook is available when MoSa has tips, owner pay, one-time items, corrections, or other period-specific changes; and
- the employee and company go-live review has no blocking setup item.

Never use an email subject, attachment filename, employee name, or an old MoSa company as the sole identity for a payroll fact. The selected company, pay period, retained source-package revision, stable employee mapping, and review ID are the controls that matter.

## 1. Open the correct payroll

1. Select the clean MoSa company in Cornerstone.
2. Open **Pay Periods** and choose the expected dates.
3. Confirm the company name, start date, end date, pay date, and run purpose before entering anything.
4. Stop if the page is a migration rehearsal, parallel-only sandbox, archived company, or unexpected client.

## 2. Prepare the source package

1. Choose **Import (MoSa)**.
2. If MoSa needs a workbook, choose **Download workbook**. Send that generated workbook for this pay period; do not reuse an old blank workbook.
3. MoSa continues to provide the Revel PDF. The PDF supplies regular and overtime hours. Cornerstone ignores Revel pay rates and pay amounts.
4. Use the generated workbook only for changes that Revel does not contain:
   - Mo and Sara's separate period-pay amounts;
   - tips and whether each employee already received those tips;
   - one-time earnings or deductions;
   - approved hour corrections;
   - new hires, terminations, status changes, or wage changes that need review; and
   - loan information or other exceptional instructions requested by the template.
5. Recurring loans, 401(k) elections, employer-match rules, and other recurring setup belong in Cornerstone employee configuration. Do not silently recreate them as one-time workbook values.

## 3. Upload and review every source row

1. Upload the current Revel PDF and, when used, the completed Cornerstone workbook.
2. Review the retained package revision and verified-source count.
3. Give every source row one explicit outcome:
   - **Include in this payroll**;
   - **Exclude from payroll**, with a reason;
   - **Move to a future payroll**, with a reason and named future period; or
   - **Informational only**, with a reason.
4. Resolve every unmatched or duplicate employee. A suggested name match must be checked against the person, not accepted from spelling similarity alone.
5. Confirm that Mo and Sara each have a separate period-pay amount. A combined owner amount is not acceptable.
6. Review hours, overtime, payroll rate source, tips, loan deductions, one-time items, and warnings for every included row.
7. Apply the package only when the interface reports no unresolved rows or blocking errors.

The source files are retained with fingerprints. Do not rename, overwrite, or delete a retained source to fix an error.

## 4. Handle a corrected email or attachment

If MoSa sends a replacement or says to disregard an earlier file:

1. Reopen **Import (MoSa)**.
2. Select that the corrected package replaces the current revision.
3. Record what changed in plain language.
4. Upload the complete corrected PDF/workbook set, not only the changed page.
5. Review and apply the new revision.
6. Recalculate payroll and obtain a new client approval. An approval for the replaced revision is no longer valid.

Never edit a previously retained source package or keep an old calculation approved after the source changes.

## 5. Calculate and review

1. Choose **Calculate Payroll**.
2. Review every warning and blocker.
3. Compare at least these employee-level facts with the authoritative parallel source:
   - regular and overtime hours;
   - pay rate or separate owner period pay;
   - taxable tips and tips already paid out;
   - recurring and one-time earnings;
   - employee loans and remaining balances;
   - employee 401(k) and employer contribution;
   - other deductions and reimbursements;
   - DRT withholding, Social Security, and Medicare; and
   - gross and net pay.
4. Generate the payroll register, tax summary, retirement/loan detail when applicable, checks or check register, and final-record preview.
5. Complete [the parallel-run validation template](01-PARALLEL-RUN-VALIDATION-TEMPLATE.md). A company-level total is not a substitute for employee-level reconciliation.

If any value exceeds the template tolerance, stop. Keep QuickBooks authoritative, record the discrepancy, and follow [the issue-remediation procedure](05-ISSUE-REMEDIATION-LOG.md).

## 6. Record exact client approval

1. Send or present the reports for the calculation revision shown in Cornerstone.
2. Require an unambiguous approval of that payroll. “Received” or “thank you” is not approval.
3. Use the client portal approval, or choose **Record Email Approval** and retain the exact approval evidence.
4. Confirm the displayed review ID is still the same after approval.

Any source, setup, or calculation change invalidates the old approval and requires recalculation and a new approval.

## 7. Parallel-cycle disposition

For a required QuickBooks comparison cycle:

1. Keep the Cornerstone period marked as a parallel comparison.
2. Do not bypass the **Parallel comparison · cannot commit** control.
3. Record every difference and finish the validation template.
4. Obtain operator and second-reviewer signoff.
5. Update the MoSa cutover record. Only two consecutive passing live periods count.

For a post-cutover Cornerstone-primary cycle, follow the same source, calculation, approval, and second-review steps, then choose **Commit & Finalize**. A committed payroll is corrected through the supported correction/void/replacement workflows; it is never rolled back by deleting database rows.

## 8. After commitment

1. Confirm the period shows **Committed / processed**.
2. Prepare and print physical checks as applicable. Printing means prepared, not paid.
3. Record check delivery only when the instrument is actually released to the employee.
4. Record clearing only from reviewed bank evidence.
5. Review liability obligations and record remittance evidence when Cornerstone makes the payment.
6. Retain filing acceptance evidence after the government system accepts a filing. Generating a form is not filing it.
7. Generate and retain the final payroll record and required client reports.

Direct deposit is outside this implementation.

## Hard stops

Do not approve, commit, or cut over when any of these is true:

- wrong company or pay-period dates;
- an unresolved source row, duplicate, stale revision, or missing current attachment;
- an unresolved employee setup or document-readiness blocker;
- owner pay is combined or ambiguous;
- a loan balance, repayment rule, or 401(k) election is not supported by reviewed setup evidence;
- the client has not explicitly approved the current review ID;
- a tax, gross, net, check, or employee-count difference exceeds tolerance;
- a P1 or blocking correction remains open; or
- the recovery and cutover gates have not been signed.

## Evidence to retain

Save one completed validation record per cycle under `docs/rollout/evidence/mosa/` using the naming convention in [the rollout index](README.md). The record must identify the source-package revision, review ID, operator, reviewer, comparison result, discrepancies, reports produced, and whether QuickBooks or Cornerstone was authoritative for payout.

MoSa becomes eligible to leave QuickBooks Payroll only after [every cutover gate](03-CUTOVER-GATE-CRITERIA.md) passes. Two passing totals without employee-level evidence, recovery readiness, operator acceptance, and signed approval do not qualify.
