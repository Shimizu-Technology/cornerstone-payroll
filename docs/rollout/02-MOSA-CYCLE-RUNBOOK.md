# MoSa payroll cycle runbook

> For the step-by-step staff guide to the current app (two-file import, expected entries, **Download preview**, client review and commit), use [MoSa biweekly payroll cycle](../runbooks/MOSA_PAYROLL_CYCLE.md). This page keeps the rollout controls: parallel cycles, cutover evidence and hard stops.

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

## 6. Publish the preview and obtain exact client approval

1. After calculation and staff review, choose **Approve**. When **Require client approval before payroll commit** is on, this publishes the current revision's PREVIEW checks and pay stubs to the client portal and records an update notification. With the setting off, staff approve and commit without publishing a client review or notifying the client. Staff approval does not require a client decision first.
2. The assigned client opens the pay run and uses **Review preview → View preview** or **Download preview**. These watermarked documents are for review before commitment.
3. The client either acknowledges and chooses **Approve this revision** (optional note), or chooses **Request changes** with a required note. Both decisions record the user, time and revision and notify the client's configured staff recipients.
4. For an emailed approval, staff choose **Record Email Approval** on the approved run, select the assigned client user and retain the explicit approval evidence reference. “Received” or “thank you” is not approval.
5. For a change request, choose **Unapprove to make changes**, correct the inputs, recalculate and approve again. Unapprove withdraws the revision and its client approval while retaining the original evidence. Even unchanged amounts require a new decision after unapprove. The new publication notifies the client again.
6. Confirm the current revision has client approval before **Commit** when **Require client approval before payroll commit** is enabled for that company. A pending change request on the current revision blocks commit even if the setting is later turned off. Unapprove to make the requested changes. Financial/source/setup gates still apply.

The portal retains revision and change-request history. Client preview access is company-scoped, revision-bound and audited. Preview downloads never assign check numbers or mark checks printed. A changed calculation cannot use an older revision's decision.

**Payroll files:** use this area for source files, messages and earlier uploaded-draft history. New manual draft-PDF uploads, posting, draft decisions and manual mark-paid are retired. Use **Open payroll preview review** for the single approval flow. For live runs, paid status follows the actual pay run commit; outstanding client file requests keep the files period in review until accepted or withdrawn. Earlier periods without a live run retain their original status.

**Runs already approved at deployment:** existing current shared revisions on approved runs are recognized as published; an exact existing client approval remains usable if its checksum still matches. No historical notification is sent automatically. If an approved run has no shared review package, unapprove and re-approve it to publish a preview. A client approval recorded while the run was only calculated is retained as history and replaced at staff approval, requiring the client to review the published revision. Committed payroll and earlier Payroll files history remain readable. This rollout does not mass-approve or commit anything.

Email delivery uses the existing portal configuration and recipient preferences. Publication and decision events are retained even when delivery is disabled or no recipient is configured; verify recipient setup before the live cycle.

**Notification rollback note:** before rolling back migration `20261127030000` (`AddDeliveryAttemptSnapshotToPortalNotificationDeliveries`), drain or clear any pending or claimed `portal_notification_deliveries` rows whose `batch_key` starts with `portal-notification-v2-`. The `down` migration refuses to drop `attempted_payload` while those rows remain so a previous release cannot re-render a different payload under an existing v2 idempotency key.

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
- at commit only: required client approval of the current published review ID is missing, or the client requested changes (even if the setting is now off);
- a tax, gross, net, check, or employee-count difference exceeds tolerance;
- a P1 or blocking correction remains open; or
- the recovery and cutover gates have not been signed.

## Evidence to retain

Save one completed validation record per cycle under `docs/rollout/evidence/mosa/` using the naming convention in [the rollout index](README.md). The record must identify the source-package revision, review ID, operator, reviewer, comparison result, discrepancies, reports produced, and whether QuickBooks or Cornerstone was authoritative for payout.

MoSa becomes eligible to leave QuickBooks Payroll only after [every cutover gate](03-CUTOVER-GATE-CRITERIA.md) passes. Two passing totals without employee-level evidence, recovery readiness, operator acceptance, and signed approval do not qualify.
