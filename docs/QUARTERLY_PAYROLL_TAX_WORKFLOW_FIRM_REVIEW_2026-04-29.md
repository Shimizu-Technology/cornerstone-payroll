# Quarterly Payroll Tax Workflow

Date: April 29, 2026

## Overview

For each payroll client, the app should help track the quarterly payroll tax work from start to finish. The goal is to make sure staff know what needs to be prepared, what needs to be paid, what needs to be filed, and what proof should be saved for each client.

At a high level, there appear to be two separate tracks:

- Guam wage withholding and Guam quarterly reporting
- Federal Social Security and Medicare reporting

The app should keep these separate so staff do not accidentally mix Guam withholding payments with federal Form 941 reporting.

## Confirmed Direction - 2026-05-16

After reviewing GuamTax, IRS guidance, screenshots from the GuamTax filing screens, and the Cornerstone CEO workflow transcript, we know enough to implement this properly.

The product should become a quarterly compliance packet workflow, not just a set of disconnected reports. For each company and quarter, the app should show what has to be prepared, what numbers support each return, what must be entered into GuamTax or IRS forms, what has been paid or filed, who is responsible, what proof was saved, and whether the packet ties out.

The key operating rules are:

- Quarterly payroll filing periods are based on pay date/check date, not pay-period end date.
- Cornerstone/the accounting firm files the returns on behalf of clients.
- The quarterly Guam filings are W-1 and SWICA/SW-2.
- The federal quarterly filing is IRS Form 941.
- Ordinary Guam income tax withholding belongs in the Guam Form 500/W-1 track, not in federal Form 941 lines 2 or 3.
- Form 941 for Guam employers should skip lines 2 and 3 by default unless the employer has employees subject to U.S. income tax withholding.
- Cornerstone's operating preference is to deposit Form 500 and federal payroll tax amounts every pay period, even if the legal deposit schedule might allow less frequent deposits.
- The app should still calculate and display the legal deposit schedule, because early/pay-period deposits are a firm policy rather than the rule itself.
- Quarterly work should be internally targeted for completion in the first week after quarter end, even though the official due date is generally the last day of the month after quarter end.

## Implementation Note - 2026-05-17

The first implementation slice creates the pay-date based quarterly compliance packet and adds prefilled official PDF downloads for:

- IRS Form 941
- IRS Schedule B for Form 941
- Guam W-1 Employer's Quarterly Tax Return
- Guam SW-2 Employer Quarterly State Wage Report

The app uses stored official PDF templates and overlays calculated packet data onto them, similar to the existing Form 500 workflow. The Guam W-1 and SWICA/SW-2 PDFs are intended as staff review aids and filing guides because GuamTax is still the filing system of record. Staff should download/review the PDF, then enter or upload the same values in GuamTax and save the filing confirmation back to the packet workflow when that task layer is added.

## Core Product Model

### Quarterly Compliance Packet

Create a quarterly packet per company, year, and quarter. The packet should be pay-date based and contain:

- Company and quarter metadata
- Official due date
- Internal target date
- Assigned staff member
- Reminder recipients
- Packet status
- Review status
- Notes
- Proof attachments
- Filing confirmations
- Payment confirmations
- Exceptions and tie-out explanations

Recommended packet statuses:

- Not started
- In progress
- Needs review
- Ready to file
- Filed
- Paid
- Filed and paid
- Not required
- Exception

The packet should include separate task sections for:

- Form 500 deposits
- W-1 quarterly Guam withholding return
- SWICA/SW-2 quarterly wage report
- Federal Form 941
- Schedule B, only when required

Annual items such as W-2GU/W-3 and 1099-NEC can be added later using the same packet/task pattern.

### Source Of Truth

The app should not rely on staff manually cleaning QuickBooks-style spreadsheets. The transcript showed that the current process breaks down because reimbursements, rent, loans, allotments, vacation, tips, salaries, and other pay codes are mixed together in a payroll summary.

Before generating final filing packets, the app needs a pay component taxability map. Every earning, reimbursement, deduction, tip, or adjustment type should define whether it counts for:

- Gross pay display
- Guam withholding wages
- SWICA wages
- Social Security wages
- Social Security tips
- Medicare wages and tips
- Additional Medicare wages
- Form 941 worksheet lines
- W-2GU wages
- Non-taxable reimbursement reporting

This is critical. If reimbursements, rent pass-throughs, loan repayments, or allotments are included in taxable wage totals, the app can generate polished but wrong returns.

## Report And Worksheet Rules

### Pay-Date Basis

All quarterly compliance reports should include payroll by pay date/check date.

Example:

- Pay period ends March 29.
- Check/pay date is April 2.
- The wages belong to Q2, not Q1.

The app may still support period-end reporting for operational reports, but compliance packets should default to pay date and label that clearly.

### Flexible Reporting Periods

Reports should support:

- Pay period
- Quarter
- Year
- Custom date range

Where the basis matters, the UI/API should make the basis explicit:

- Pay date/check date
- Pay period start/end

Quarterly compliance reports should use pay date by default.

### Quarterly Payroll Summary By Employee

The CEO's current QuickBooks source report is "Payroll Summary by Employee" for the quarter. The app should provide a native version that shows:

- Employee
- SSN or masked SSN where appropriate
- Pay component breakdown
- Taxable Guam/SWICA wages
- Social Security wages
- Social Security tips
- Medicare wages/tips
- Guam income tax withheld
- Social Security employee/employer tax
- Medicare employee/employer tax
- Additional Medicare tax
- Reimbursements and non-taxable amounts separately
- Quarter totals
- Tie-out totals against W-1, SWICA, and Form 941 worksheets

This report should be exportable to Excel because staff already use Excel for review and reconciliation.

## Form 500 Deposit Track

Form 500 is the Guam Depository Receipt for Income Tax Withheld. The app already has native Form 500 support, and this should become part of the quarterly packet.

For each pay period with Guam income tax withholding, the packet should show:

- Pay date
- Pay period start/end
- Guam withholding amount
- Form 500 amount
- Quarter ending date
- Payment due date based on legal schedule
- Firm policy due date based on pay-period deposit preference
- Paid date
- Payment amount
- Confirmation number
- Receipt attachment
- Notes

Cornerstone's operational policy is to deposit Form 500 with every pay period to keep things simple and avoid late payments. The app should support that as a company or organization default.

However, the app should still understand the legal schedule:

- If quarterly withheld income tax is below the threshold where payment with W-1 is allowed, pay-period deposit is earlier than required.
- Monthly depositors generally deposit by the 15th of the following month.
- Semiweekly depositors follow the applicable Wednesday/Friday pattern.

The app should present these as compliance checks without forcing the firm to abandon its pay-as-you-go policy.

## W-1 Guam Quarterly Withholding Return

W-1 is filed through GuamTax under Quarterly -> W-1.

The app should prepare a W-1 filing guide and worksheet that tells staff exactly what to enter in GuamTax.

The W-1 worksheet should include:

- Company EIN
- Company name and address
- Quarter ending month/year
- Daily withholding liabilities by actual pay date
- Monthly liability totals
- Total Guam income tax withheld
- Form 500 payments/deposits for the quarter
- Credits and adjustments
- Balance due or overpayment
- Filing date
- Confirmation number
- Filed return or receipt attachment

The guided filing flow should explain:

1. Log in to GuamTax.
2. Choose Quarterly.
3. Select W-1.
4. File W-1 for the correct quarter ending month/year.
5. Enter daily/monthly liabilities from the app worksheet.
6. Review Form 500 payments retrieved by GuamTax.
7. Enter credits or adjustments only if staff has support.
8. Confirm balance due or overpayment.
9. File and save/attach proof in the app.

Tie-out checks:

- Total W-1 liability should equal total Guam withholding from pay-date based payroll for the quarter, plus or minus reviewed adjustments.
- Form 500 deposits should reconcile to the amount shown/retrieved in GuamTax.
- Any difference must be explained before marking the W-1 task ready or filed.

## SWICA / SW-2 Quarterly Wage Report

SWICA is the Guam quarterly SW-2 wage report. It is filed through GuamTax under Quarterly -> SWICA/SW-2.

The app should produce a SWICA worksheet first, then eventually a SWICA upload file.

The SWICA worksheet should include only employees paid in the quarter. Employees with no quarter wages should be excluded from the filing detail unless there is a specific reason to include a corrected/terminated record.

For each employee, the packet should show:

- SSN
- Name
- Address
- Employment status
- Termination date, if applicable
- Quarter/year
- Quarterly wages/tips/other compensation
- Quarterly Guam income tax withheld

Packet totals should include:

- Employee count
- Total wages
- Total tax withheld

The guided filing flow should explain:

1. Log in to GuamTax.
2. Choose Quarterly.
3. Select SWICA/SW-2.
4. Use File SWICA for manual entry or Upload SWICA for upload-file filing.
5. Enter or upload employee detail from the app worksheet.
6. Confirm employee count, total wages, and total tax withheld match the app.
7. File and save/attach proof in the app.

Future upload support:

- Generate the GuamTax-required ASCII upload file.
- Validate field lengths and required fields before export.
- Support multiple locations when the GuamTax account has multiple business license/location records.
- Block duplicate SSNs in the same quarter unless the filing scenario supports a correction.

Tie-out checks:

- SWICA total wages should tie to taxable SWICA wages from the quarterly payroll summary.
- SWICA total withholding should tie to Guam income tax withheld.
- Employee count should match employees with reportable quarter wages.

## Federal Form 941 Worksheet

The current app feature named "Form 941-GU" should be renamed and reframed as "Federal Form 941 Worksheet."

Form 941 is filed with the IRS/U.S. Treasury, not Guam DRT. The old "941-GU" naming is misleading for the current workflow.

For Guam employers:

- Skip Form 941 lines 2 and 3 by default.
- Only populate lines 2 and 3 if the company has employees subject to U.S. income tax withholding.
- Guam income tax withholding should stay in the Form 500/W-1 track.

The Form 941 worksheet should include:

- Employer EIN/name/address
- Quarter checkbox
- Line 1 employee count for the required pay period date:
  - March 12 for Q1
  - June 12 for Q2
  - September 12 for Q3
  - December 12 for Q4
- Lines 2 and 3 skipped/blank by default for Guam employers
- Line 5a taxable Social Security wages
- Line 5b taxable Social Security tips
- Line 5c taxable Medicare wages and tips
- Line 5d taxable wages/tips subject to Additional Medicare Tax withholding
- Line 5e total Social Security and Medicare taxes
- Adjustments for fractions of cents, sick pay, tips/group-term life where applicable
- Line 10 total after adjustments
- Line 11/12 credits where applicable
- Line 13 total deposits
- Balance due or overpayment
- Part 2 deposit schedule and liability details
- Signature/preparer fields as manual review fields

Tax calculation rules:

- Social Security wages and Social Security tips must be separate.
- Social Security wages/tips must respect the annual Social Security wage base.
- Medicare wages and tips are combined.
- Additional Medicare applies above the IRS threshold.
- Stored payroll taxes should be used for reconciliation, but official line calculations should be visible.

Tie-out checks:

- Line 5a + 5b taxable amounts should reconcile to Social Security taxable wage/tip totals after wage-base caps.
- Line 5c should reconcile to Medicare taxable wages and tips.
- Line 5e should reconcile to expected combined employer/employee Social Security and Medicare tax, plus Additional Medicare where applicable.
- Part 2 monthly or Schedule B liability totals must equal Form 941 line 12.
- Deposits must reconcile to recorded federal payroll tax payments.

## Federal Deposit Schedule And Schedule B

The app should calculate a suggested Form 941 deposit schedule for each company/year using the IRS lookback rules, while allowing staff to override it.

For Form 941 filers:

- The lookback period for a calendar year is the four quarters from July 1 through June 30 before that calendar year.
- If Form 941 line 12 taxes in the lookback period were $50,000 or less, the employer is a monthly schedule depositor.
- If Form 941 line 12 taxes in the lookback period were more than $50,000, the employer is a semiweekly schedule depositor.
- If tax liability reaches $100,000 in a deposit period, the next-day deposit rule applies.
- The deposit schedule is not determined by how often employees are paid or how often deposits are actually made.

Cornerstone's firm policy is to pay federal payroll taxes every pay period to avoid scrambling. The app should support this as a practical payment workflow while still indicating the legal deposit classification.

Schedule B should be generated or required when:

- The employer is a semiweekly schedule depositor for any part of the quarter.
- The employer otherwise meets IRS requirements that call for Schedule B.

Schedule B is a liability schedule by pay date, not a payment list. The app should not confuse federal tax payments/deposits with tax liability dates.

## Review And Quality Control

The app should make the quarterly packet reviewable before filing.

Recommended readiness checks:

- All included payroll is selected by pay date/check date.
- Pay component taxability mapping is complete for the quarter.
- Reimbursements, rent pass-throughs, loan repayments, and other non-taxable amounts are excluded from taxable wage totals.
- W-1 withholding total ties to pay-date based Guam withholding.
- W-1 Form 500 payments reconcile to payment records or reviewed exceptions.
- SWICA total wages tie to SWICA taxable wages.
- SWICA total withholding ties to Guam tax withheld.
- SWICA employee count excludes zero-pay employees.
- Form 941 Social Security wage base caps are applied correctly.
- Form 941 wages and tips are separated correctly.
- Medicare wages/tips are combined correctly.
- Additional Medicare is calculated and reviewed where applicable.
- Form 941 Part 2 liability totals equal Form 941 line 12.
- Required proof/confirmation fields are present before marking a task filed or paid.

If a tie-out fails, the app should show the difference and require either a correction or a reviewed explanation.

## Implementation Plan

### Phase 1: Data foundation

Build or refine:

- Pay component taxability mapping
- Quarter/custom date report filters by pay date
- Quarterly payroll summary by employee
- Non-taxable amount separation
- Employee-level wage/tax rollups
- Company-level compliance settings:
  - Form 500 deposit policy
  - Federal Form 941 deposit schedule
  - Internal target days after quarter end
  - Reminder recipients

### Phase 2: Compliance packet shell

Build:

- Quarterly compliance packet model
- Packet tasks
- Statuses
- Assignments
- Notes
- Due dates
- Internal target dates
- Proof uploads
- Confirmation fields
- Audit trail

### Phase 3: Guam withholding packet

Build:

- Form 500 deposit ledger in the packet
- W-1 worksheet
- W-1 filing guide
- W-1 tie-out checks
- Form 500 payment reconciliation

### Phase 4: SWICA packet

Build:

- SWICA employee detail worksheet
- SWICA filing guide
- SWICA tie-out checks
- Excel export
- Later: ASCII upload file generation

### Phase 5: Federal 941 packet

Build:

- Rename/reframe 941-GU to Federal Form 941 Worksheet
- Guam-specific line 2/3 skip behavior
- Form 941 worksheet and Excel/PDF output
- Federal deposit/payment ledger
- Schedule B liability worksheet when required
- Deposit schedule determination and staff override

### Phase 6: Reminders and operational polish

Build:

- Official due date reminders
- Internal first-week target reminders
- Escalation reminders for unfiled/unpaid tasks
- Filing/payment history views
- Packet dashboard across companies

## Known Current App Changes Needed

- Rename "Form 941-GU Quarterly Report" to "Federal Form 941 Worksheet" or similar.
- Stop describing Form 941 as a Guam DRT filing.
- Default Form 941 lines 2 and 3 to skipped/blank for Guam employers.
- Ensure Guam withholding is reported through Form 500/W-1 workflows, not Form 941.
- Add or strengthen pay component taxability mapping before relying on generated quarterly filings.
- Add pay-date based quarter/custom range reporting across compliance reports.
- Build SWICA as an employee-level wage report, not just aggregate totals.
- Exclude zero-pay employees from SWICA filing detail unless needed for a specific correction/status scenario.
- Add tie-out requirements before marking packets ready/filed.

## What Needs To Be Done Each Quarter

### 1. Track Form 500 wage withholding payments

For each payroll run, the app should calculate the Guam income tax withholding from employee wages.

The app should help staff track:

- The withholding amount from each payroll
- Whether a Form 500 payment needs to be made
- Who is responsible for making the payment
- The payment date
- The payment amount
- The confirmation number or receipt
- Any notes or exceptions

The app should also make it easy to compare Form 500 payments against the quarter-end Guam W-1 return.

Questions to confirm:

- Is Form 500 paid after every payroll, monthly, quarterly, or based on client-specific rules?
- Who normally makes the payment?
- What proof should be saved?
- Are there different payment timing rules for different clients?

### 2. Prepare the Guam W-1 quarterly return

The Guam W-1 appears to be the quarterly return for Guam wage withholding.

The app should help staff prepare a W-1 worksheet for each client and quarter showing:

- Total Guam income tax withheld
- Form 500 payments already made
- Monthly or daily liability detail, if required
- Credits or adjustments, if any
- Any balance due
- Filing status
- Filing confirmation number
- Filed date
- Copy of the filed return or receipt

Questions to confirm:

- Is W-1 the correct quarterly Guam withholding return for these payroll clients?
- What exact numbers are entered on the W-1?
- When is daily liability detail required versus monthly liability detail?
- What information does the firm need from the app to file W-1 efficiently?

### 3. Prepare federal Form 941

Federal Form 941 should be treated separately from Guam wage withholding.

Our current understanding is that Form 941 is used for federal Social Security and Medicare reporting. For Guam employers, the federal income tax withholding lines generally do not apply unless there are employees subject to U.S. federal income tax withholding.

The app should help staff prepare a Form 941 worksheet showing:

- Number of employees for the quarter
- Social Security wages
- Social Security tax
- Medicare wages
- Medicare tax
- Additional Medicare tax, if any
- Adjustments, if any
- Total federal employment tax liability
- Deposit schedule information
- Filing status
- Filing confirmation number
- Filed date
- Copy of the filed return or receipt

Questions to confirm:

- Do Guam payroll clients currently file standard IRS Form 941?
- Should Guam wage withholding ever appear on Form 941?
- Are there any clients where federal income tax withholding does apply?
- Who normally files Form 941?

### 4. Determine whether Schedule B is required

Schedule B should only be included when required. It is not a list of payments. It is a record of tax liability by wage payment date.

The app should help staff determine whether each client is:

- A monthly depositor
- A semiweekly depositor
- Subject to the $100,000 next-day deposit rule

If Schedule B is required, the app should prepare a worksheet showing liabilities by pay date and confirm that the total matches the Form 941 total.

Questions to confirm:

- How does the firm determine each client's deposit schedule?
- Should the app calculate the schedule or should staff set it manually?
- What should happen if a client crosses the $100,000 next-day deposit threshold?
- Should the app always show a Schedule B preview, even when it is not filed?

### 5. Track SWICA quarterly filing

SWICA appears to be a separate Guam quarterly filing.

The app should help staff track:

- Whether SWICA is required for each client
- The employee wage data needed
- Whether the filing is done manually or by upload
- Filing date
- Confirmation number
- Copy of the filed report or receipt

Questions to confirm:

- Is SWICA required for all payroll clients?
- What data needs to be submitted?
- Is there a file format the app should eventually generate?
- Who normally files SWICA?

## Suggested App Workflow

The app should have a quarterly compliance checklist for each client.

Each client and quarter would show items like:

- Form 500 payments
- Guam W-1 return
- Federal Form 941
- Schedule B, if required
- SWICA, if required
- W-2GU/W-3 annual filing, when applicable
- 1099-NEC annual filing, when applicable

Each item should have a simple status:

- Not started
- In progress
- Waiting on client
- Ready for review
- Filed
- Paid
- Not required

Each item should also allow staff to store:

- Due date
- Assigned person
- Notes
- Payment amount
- Filing confirmation number
- Receipt or PDF
- Final review checkbox

## Suggested Implementation In The App

### Phase 1: Reminders and checklists

Start with a practical checklist and reminder system.

The app would create quarterly tasks for each client and show what needs attention. Staff would be able to mark items complete, add notes, and upload proof.

This phase does not need to file anything automatically. It just makes sure nothing gets missed.

### Phase 2: Worksheets

Next, the app should prepare worksheets for the forms.

These worksheets would pull numbers from payroll and show staff what should be reviewed before filing:

- Form 500 payment summary
- W-1 quarterly summary
- Form 941 worksheet
- Schedule B worksheet, if required
- SWICA summary, if required

Staff would still review and file using the appropriate official system.

### Phase 3: Filing records

After filing or payment, staff should record what happened.

The app should store:

- Filed by
- Filed date
- Confirmation number
- Amount paid
- Payment date
- Receipt or PDF
- Notes

This gives each client a clean quarterly history.

### Phase 4: Exports or deeper automation

Only after the workflow is confirmed should the app generate upload files or support deeper filing automation.

Possible future exports:

- SWICA upload file
- W-2GU/W-3 electronic filing file
- Schedule B worksheet export
- W-1 support worksheet

## Due Dates To Confirm

Based on public guidance, these appear to be the main quarterly dates:

- W-1 for Q1: April 30
- W-1 for Q2: July 31
- W-1 for Q3: October 31
- W-1 for Q4: January 31
- SWICA appears to follow the same quarterly dates
- W-2GU to DRT and employees: January 31
- IRS Form 941 is generally due by the last day of the month after the quarter ends

Questions to confirm:

- Are these the dates the firm uses in practice?
- Do holidays change any of these dates?
- Are there client-specific exceptions?
- How many days before each due date should the app remind staff?

## Current App Concern

The app currently has a feature called "Form 941-GU Quarterly Report."

That may need to be changed.

Instead of one combined report, the app should likely separate this into:

- Guam W-1 worksheet
- Form 500 payment reconciliation
- Federal Form 941 worksheet
- Schedule B worksheet, if required

This should be confirmed before more automation is built around the current report.

## Items For The Firm To Confirm

Please confirm:

1. Which forms are required for Guam payroll clients each quarter.
2. Which payments are made after payroll versus monthly or quarterly.
3. Whether Guam withholding belongs only on Form 500/W-1.
4. Whether Guam withholding should ever appear on federal Form 941.
5. How each client's federal deposit schedule is determined.
6. When Schedule B is required.
7. Whether SWICA should be included in the quarterly workflow.
8. What proof should be saved for each payment and filing.
9. What reminders would be most useful.
10. Any special client situations the app should support.

## References Reviewed

- IRS Instructions for Form 941: https://www.irs.gov/instructions/i941
- IRS Publication 15, Employer's Tax Guide: https://www.irs.gov/publications/p15
- IRS Schedule B Instructions: https://www.irs.gov/instructions/i941sb
- GuamTax W-1 E-Filing Help: https://www.guamtax.com/help/help_w1.html
- GuamTax Tax Calendar: https://www.guamtax.com/info/calendar.html
- PayGuam payment types: https://pay.guam.gov/pg/payments.aspx
- GuamTax W-3/W-2GU E-Filing: https://www.guamtax.com/efile/w2w3.html
- GuamTax SWICA E-Filing Help: https://www.guamtax.com/help/help_swica.html
