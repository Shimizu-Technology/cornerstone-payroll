# Payment delivery and earnings statements

An earnings statement describes payroll activity even when deductions leave no money to pay. Statement printing and payment issuance are separate operations.

## Printing statements

Open a committed pay run’s **Checks & direct deposit** section. **Earnings statements** lists meaningful payroll activity across delivery methods. Statement-only records appear first with **No payment issued**, including wages fully consumed by loan repayment or other deductions. View, print, or download one statement, all eligible statements, or an explicit selection. Search filters the visible selection; already selected employees remain selected until cleared.

Paper-check packages remain a separate workflow for positive-net payments. Printing a statement never assigns a check number, marks a check issued, sends a bank transfer, or changes wages, deductions, loan repayments, YTD, or liabilities. Voided, legacy-excluded, and genuinely empty records are not printable statements. Negative corrective payroll and offsetting financial activity remain statement-worthy and do not imply a payment.

## Changing payment delivery

Use **Change method** on the employee’s statement row, or expand **Review payment methods and amounts**. The dialog checks the current payment history before enabling a save. The default scope is this payroll only. Select **Also use this method as the employee’s future payroll default** to save both scopes in one transaction.

Before commitment, changing an approved run requires review and approval again. Import and calculation paths save the run’s delivery choice; later employee-default edits preserve existing choices. Older inherited choices are explicitly retained, and any approval that must be renewed is identified by pay-run number.

After commitment, confirm the payment remains unpaid and enter a reason. An unissued paper check changed to direct deposit retires its number; an unpaid direct deposit changed to paper receives a new number. There is no payment operation for zero or negative net amounts.

For a prepared, printed, downloaded, or delivered check, the original instrument must be recovered/cancelled and unable to be paid. Record its cancellation evidence reference and explicit unpaid/cancellation confirmations. The dialog submits the original check identity so a concurrent replacement cannot be cancelled by a stale screen. This is a delivery-only correction: the earned-pay record remains active and committed. Cleared and voided payments are blocked. Do not use payroll void, financial replacement, or recalculation merely to change delivery. Linked AIRE entries receive cancellation evidence for the original physical payment without reversing earned payroll.

Direct deposit is a recorded delivery preference here. Enrollment, transmission, and confirmation occur with the employer/bank outside the application. Saving a preference or printing a statement does not send money or prove a transfer completed.

## Future defaults and client names

**Employees → Pay setup → Payment method → Change future payment method** updates only the future default. The rest of the employee profile and existing run delivery choices remain intact. Saved changes and refresh failures are reported separately.

Organization administrators can use **Client Management → Rename** to change the name displayed on newly generated reports and statements. This sends only the name, preserving EIN, bank configuration, and the check-number sequence. Use the employer’s confirmed business spelling; migration/test provenance remains in the existing workspace metadata. Existing downloaded files, retained source evidence, confirmed print packages, and saved filing fields are not rewritten. After an audited name-only rename, a prepared package can retain its original issuer name only when its complete rendered input digest and all existing verification checks still match. Check, payroll, employee, or printer changes can still make it stale; mixed or unaudited name changes do not authorize historical-name fallback. New reports and packages use the current name.

## Validation

Backend regressions cover statement eligibility and exclusions, both payment directions, unchanged financial totals, imported/default method stability, renewed approvals, original-number concurrency, repeated requests, cancellation audit and linked AIRE acknowledgements. Browser release coverage exercises actual statement rendering/downloads and combined/future-only changes at phone and desktop widths using synthetic data. Required backend, frontend, and browser checks gate the release.
