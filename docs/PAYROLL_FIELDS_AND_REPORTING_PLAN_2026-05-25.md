# Payroll Fields, Client-Wide Adjustments, and Reporting Plan

Date: 2026-05-25

## Why this exists

Cornerstone wants a QuickBooks-like way to create reusable payroll fields for a client/company once, then apply those fields to any employee who needs them during payroll processing.

The practical examples from Cornerstone/MoSa are:

- recurring loan deductions such as auto loans or named personal loans.
- rent/allotment/pass-through amounts that may be deducted from one employee and paid to another.
- 401(k), Roth 401(k), insurance, child support, garnishments, or other recurring deductions.
- reimbursements or non-taxable additions that should increase net pay but not taxable wages.
- employer contributions that must be reported separately from employee-paid deductions.

The goal is not to build arbitrary spreadsheet columns. The goal is to build **payroll-aware reusable fields** with clear tax treatment, payroll math, employee assignment, pay-stub/check visibility, and report visibility.

## Source context reviewed

Internal Cornerstone context:

- `Brain-Dump/work/shimizu-tech/Cornerstone/2) Meeting with Mom to go over loans.md`
- `Brain-Dump/work/shimizu-tech/Cornerstone/3) Meeting with mom and Auntie Daena to go over payroll.md`
- `Brain-Dump/work/shimizu-tech/Cornerstone/1) Meeting-with-Cornerstone-CEO-Quarterly-Returns.md`
- `docs/MOSA_LOANS_AND_IMPORT_WORKFLOW_PLAN_2026-05-20.md`

External payroll-system reference patterns:

- OnPay `Setting up payroll pay items`: company-level pay items can be configured as W-2 wages, 1099 wages, non-reported reimbursements, or imputed/other items. Non-hourly pay items are used for specific amounts during payroll processing.
- OnPay `Employee deductions: 401(k) and more`: deductions are set up at the company level first, then assigned to employees. Employee assignments can use flat amounts or percentages and may have employee-specific settings/overrides. Deductions distinguish pre-tax, post-tax, employer match, and nonelective employer contribution behavior.
- QuickBooks/desktop workflow as described by Cornerstone: payroll items/fields are reusable across employees, can show in payroll processing/review, and flow into reports.

## Current app state

The app already has several pieces of this model, but they are not yet unified into a clean client-wide payroll-field workflow.

### Existing reusable deduction infrastructure

- `DeductionType`
  - company-level type.
  - categories: `pre_tax`, `post_tax`, `employer_contribution`.
  - sub-categories: `retirement`, `insurance`, `garnishment`, `loan`, `rent`, `phone`, `allotment`, `reimbursement`, `child_support`, `other`.
- `EmployeeDeduction`
  - assigns a deduction type to one employee.
  - supports fixed amounts and percentages.
- `PayrollItemDeduction`
  - pay-period/paycheck snapshot of an applied deduction or employer contribution.

This is close to the right foundation for deductions and employer contributions.

### Existing recurring payroll adjustments

PR #90 added employee/payroll-item JSON adjustments:

- `taxable_addition`
- `non_taxable_addition`
- `pre_tax_deduction`
- `post_tax_deduction`

These are useful and safe because they snapshot onto payroll items, but they are currently employee-specific/manual entries rather than reusable company-level fields.

### Existing report gap

Some reports still present custom/adjustment activity as aggregate columns such as `Custom Earnings` and `Custom Deductions`. New client-wide payroll fields need clearer itemized reporting by field name, tax treatment, and employee-vs-employer responsibility.

## Product concept: Company Payroll Fields

Use the term **Payroll Fields** or **Payroll Codes** instead of “custom columns.”

A payroll field is a reusable company-level definition with payroll meaning.

Examples:

- `Auto Loan`
- `Nana Joe Loan`
- `Rent`
- `Cell Reimbursement`
- `401(k)`
- `Roth 401(k)`
- `Health Insurance`
- `Child Support`
- `Employer 401(k) Match`

Each field should define:

- client/company ownership.
- name and optional description.
- kind:
  - addition/earning.
  - deduction.
  - employer contribution.
- tax/report treatment:
  - taxable addition.
  - non-taxable addition/reimbursement.
  - pre-tax employee deduction.
  - post-tax employee deduction.
  - employer contribution.
- category:
  - loan, retirement, insurance, rent, allotment, reimbursement, garnishment, child support, other.
- amount mode:
  - manual each payroll.
  - flat default amount.
  - percentage of gross or eligible wages.
- default amount/percentage, if any.
- whether it should appear as a payroll-review column.
- whether it should be available to all employees or only assigned employees.
- active/inactive status.
- report ordering/grouping.
- optional payee/remittance metadata for checks/reports.
- optional integration/link to loan ledger or retirement reporting.

## Employee assignment model

Company-level fields should be assigned to employees who need them.

An employee assignment should define:

- employee.
- payroll field.
- active/inactive.
- employee-specific default amount or percentage.
- optional start/end dates.
- optional per-pay-period cap or annual cap.
- optional notes.
- optional linked `EmployeeLoan` for loan fields.

Examples:

```text
Employee: Mo
Payroll Field: Auto Loan
Kind: Deduction
Treatment: Post-tax
Default: $75.00/check
Linked loan: Auto Loan #123
```

```text
Employee: Sara
Payroll Field: Rent from Charlie
Kind: Addition
Treatment: Non-taxable addition
Default: $250.00/check
```

```text
Employee: Charlie
Payroll Field: Rent to Sara
Kind: Deduction
Treatment: Post-tax deduction
Default: $250.00/check
```

```text
Employee: Employee A
Payroll Field: 401(k)
Kind: Deduction
Treatment: Pre-tax deduction
Default: 5% of gross
```

## Payroll-run snapshot model

When payroll is calculated or imported, employee assignments should snapshot into payroll items as field entries.

The snapshot should preserve:

- payroll item.
- payroll field definition id, if any.
- label at the time of payroll.
- kind/tax treatment/category at the time of payroll.
- amount.
- source:
  - employee default.
  - manual payroll edit.
  - import.
  - system-generated employer match.
- whether it is employee-paid or employer-paid.
- optional linked loan/benefit/payee metadata.

This avoids historical drift. If a company later renames `Auto Loan`, historical checks and reports should not silently change.

## Payroll processing UX

### Company setup page

Add a **Payroll Fields** setup area.

Payroll staff should be able to:

- create a field once.
- choose a guided field type.
- choose tax treatment with plain-English help.
- choose default amount mode.
- mark whether it appears in payroll review.
- deactivate fields no longer used.

### Employee profile

Add an **Assigned Payroll Fields** section.

Payroll staff should be able to:

- add from existing company payroll fields via dropdown.
- set employee-specific default amount/percentage.
- activate/inactivate for that employee.
- optionally create a new company field from the employee screen if needed.

### Payroll run screen

During payroll review, fields should be grouped logically:

1. base pay/hours.
2. tips.
3. additions.
4. deductions.
5. employer contributions.
6. taxes/net pay.

Client-wide fields that are marked “show in payroll review” can appear as columns. Employees who do not use a field should show blank or `$0.00`.

Because clients like MoSa can have many fields, the table needs:

- horizontal scrolling.
- grouped column headers.
- column visibility controls.
- “show only non-zero/assigned fields” toggle.
- clear warnings when a field affects taxable wages vs net pay only.

## Recurring adjustment UI polish

The existing unified treatment dropdown is powerful but has too much room for operator error.

Instead, split the UI into sections:

### Additions

Operator chooses:

- taxable pay.
- non-taxable addition/reimbursement.

### Deductions

Operator chooses:

- before taxes.
- after taxes.

### Employer Contributions

Operator chooses:

- retirement.
- insurance.
- other contribution.

This aligns better with how payroll staff think and avoids accidentally choosing an addition when they intended a deduction.

## Reporting requirements

This is a core requirement, not polish.

Every payroll field should be transparent in reports, pay stubs, and checks.

Reports should distinguish:

- taxable additions.
- non-taxable additions.
- pre-tax employee deductions.
- post-tax employee deductions.
- employer contributions.
- employee-paid vs employer-paid amounts.

Reports should also support itemized field totals, not just aggregate “custom earnings” or “custom deductions.”

Required report surfaces:

- Payroll Register.
- Payroll Summary by Employee.
- Deductions & Contributions Report.
- Paycheck History.
- Retirement Plans Report.
- Pay stubs.
- Printed check stubs.
- XLSX/CSV exports.
- Client portal reports.
- Full print package.

Example report groupings:

```text
Additions by Field
- Taxable Bonus
- Rent Reimbursement
- Cell Reimbursement

Employee Deductions by Field
- 401(k)
- Auto Loan
- Health Insurance
- Child Support

Employer Contributions by Field
- 401(k) Employer Match
- Employer Health Contribution
```

Employer contributions must never be blended into employee deductions in reports.

## MoSa import compatibility rules

This work must not break MoSa imports.

Current MoSa source-of-truth behavior remains:

- MoSa loan/tip workbook tips feed taxable tips.
- MoSa `loan_deduction` remains authoritative for paycheck deduction for imported payroll items.
- Imported MoSa `loan_deduction` should not be overwritten by itemized employee deductions or loan setup.
- Current MoSa import detail preservation remains intact:
  - BOH tips.
  - FOH tips.
  - recurring loan deduction.
  - installment loan payment.
  - installment beginning/new/ending balance detail.
- MoSa imported installment loans still do **not** mutate `EmployeeLoan` ledger balances until the explicit loan-ledger integration PR.

### How Payroll Fields should interact with MoSa imports

Payroll Fields can eventually help map MoSa loan names/types to reusable company fields, but this must be introduced safely.

Safe interim rule:

- If a payroll item has `import_source` and imported `loan_deduction > 0`, the imported loan deduction remains the paycheck deduction source.
- Company payroll fields/deductions may exist for the employee, but they must not double-deduct the same imported loan amount.
- Any mapping from imported MoSa workbook loan rows to payroll fields should first be preview-only/warning-only.

Future mapping behavior:

- MoSa recurring loan rows can map to company payroll fields with category `loan`, treatment `post_tax_deduction`.
- MoSa installment loan rows can map to employee loans and payroll fields, but commit-time ledger mutation must be idempotent and separately validated.
- Imported workbook beginning/ending balances should produce warnings if they do not match the system ledger.
- Final payment capping should happen only when explicit ledger integration is enabled and reviewed.

### Anti-regression tests required

Before shipping Payroll Fields into payroll calculation, add/keep tests proving:

- MoSa imported `loan_deduction` remains authoritative when itemized employee loan deductions exist.
- MoSa imports do not create duplicate post-tax loan deductions through Payroll Fields.
- Existing MoSa tip import behavior is unchanged.
- Variable salary import guards remain unchanged.
- Pay stubs/check stubs still show imported loan deduction and payroll fields clearly.

## Recommended implementation sequence

Use **one long-lived feature branch** so the product concept stays coherent, but plan to ship it as **two reviewable PRs** if the diff becomes large.

Suggested branch:

```text
payroll-fields-client-wide-adjustments-2026-05-25
```

This gives us momentum while avoiding one risky mega-merge that touches setup, payroll calculation, payroll review UI, reports, check stubs, pay stubs, and MoSa import behavior all at once.

### PR A — Payroll Fields foundation + payroll processing UI

Goal: implement the reusable client-wide payroll field workflow and make it usable during payroll processing, while preserving existing MoSa import behavior.

Scope:

- Add company-level payroll field definitions.
- Add employee payroll-field assignments with employee-specific defaults.
- Add admin API endpoints.
- Add setup UI for company payroll fields.
- Add employee assignment UI.
- Snapshot assigned fields into payroll items/payroll runs.
- Show selected fields as grouped payroll-review columns:
  - additions.
  - deductions.
  - employer contributions.
- Allow per-period field amount overrides during payroll review.
- Reorganize current recurring adjustment UI into safer sections:
  - additions: taxable vs non-taxable.
  - deductions: pre-tax vs post-tax.
  - employer contributions.
- Keep existing JSON `payroll_adjustments` working during transition.
- Add MoSa import protection so imported loan deductions are not double-deducted by payroll fields.
- Add calculator/import/payroll-item specs proving existing payroll math still behaves correctly.

Non-goals for PR A:

- No MoSa loan ledger mutation.
- No automatic final-payment loan capping yet.
- No broad report redesign beyond what is required for pay-period/payroll review visibility.
- No removal of legacy custom adjustment fields yet.

PR A acceptance criteria:

- A payroll field can be created once for a company.
- The field can be assigned to multiple employees.
- Employee defaults populate into a payroll run snapshot.
- Payroll staff can review/edit field amounts during payroll processing.
- Additions/deductions/employer contributions are visually separated.
- MoSa imported `loan_deduction` remains authoritative and is not duplicated.
- Existing recurring payroll adjustments continue to work.

### PR B — Field-aware reports, exports, pay stubs, and check stubs

Goal: make every payroll field transparent in reporting and employee/paycheck outputs.

Scope:

- Audit all reports for current `payroll_adjustments` and new payroll-field visibility.
- Itemize field-by-field report sections.
- Update XLSX/CSV exports with field breakdowns.
- Update Payroll Register.
- Update Payroll Summary by Employee.
- Update Deductions & Contributions Report.
- Update Paycheck History.
- Update Retirement Plans Report.
- Update client portal reports.
- Update pay stubs and printed check stubs where needed.
- Ensure employer contributions are visibly separate from employee-paid deductions.
- Add report/export specs proving totals and itemized lines tie out.

PR B acceptance criteria:

- Field amounts are not hidden behind generic `Custom Earnings` / `Custom Deductions` totals where itemization is needed.
- Reports distinguish taxable additions, non-taxable additions, pre-tax deductions, post-tax deductions, and employer contributions.
- Employee-paid and employer-paid amounts are separate.
- Reports remain readable for clients with many fields.

#### PR B implementation contract (July 2026)

The reporting work follows two non-negotiable accounting rules:

1. Historical reports read `payroll_item_field_entries`, which are the immutable values and labels snapshotted when payroll was calculated. They never rebuild prior payroll from a field's current name, assignment, or employee default.
2. Multi-period operational reports use **pay date** as their basis and include only committed, reportable, non-voided payroll rows. An exact start/end range is inclusive.

Coverage:

- Payroll Register: on-screen, PDF, CSV, and Excel retain the per-payroll itemized field disclosure and treatment totals.
- Payroll Summary by Period (legacy YTD route): calendar-year or exact pay-date range, with field totals on screen and field-total/activity Excel sheets.
- Employee Pay History: exact pay-date range, with field totals on screen and itemized field activity in Excel.
- Tax Withholding Summary: year, quarter, or exact pay-date range, with supporting field reconciliation in the on-screen, PDF, CSV, and Excel outputs.
- Payroll Summary by Employee, Deductions & Contributions, Retirement Plans, pay stubs, and check stubs continue to use the shared `QuickbooksPayrollReportData` classification of snapshotted field entries.
- Paycheck History PDF includes a dedicated payroll-field detail appendix.

Official filing forms (W-2GU, 941, W-1, SWICA, 1099-NEC, and Form 500) remain fixed to their legally defined boxes and filing periods. Arbitrary business fields are not added as invented form columns; the supporting payroll register and reconciliation reports explain the amounts feeding those forms.

Custom-range selectors are intentionally provided on reports where an arbitrary period is meaningful. Statutory quarterly and annual filing forms remain constrained to their required quarter/tax-year selectors.

### PR C — MoSa loan ledger integration

Goal: after Payroll Fields and reports are stable, map MoSa loan rows and loan-type payroll fields into true loan ledger tracking.

Scope:

- Explicit loan tracking mode:
  - recurring/no-balance.
  - installment/balance-tracked.
- Match import rows to `EmployeeLoan`.
- Commit-time `LoanTransaction` creation.
- Idempotency.
- Final-payment cap.
- Paid-off handling.
- Beginning/ending balance mismatch warnings.

This stays separate because it mutates loan ledger state and should not be bundled with the field setup/reporting work.

## Smaller polish tracks

These are useful, but should not be mixed into the core payroll-field PRs unless tiny and low-risk.

### Pay periods newest-to-oldest default

Small, low-risk UI change. Can be a separate quick PR.

### Login/signup modal polish

Frontend-only polish. Separate PR.

### Recurring payroll adjustments UI polish

This overlaps strongly with Payroll Fields. Best done either:

- as part of PR #95/#96 UI work, or
- as a focused preliminary PR that only reorganizes the existing UI without changing data/maths.

## Open decisions

- Final naming: “Payroll Fields” vs “Payroll Codes” vs “Pay Items.”
- Whether client-wide fields should appear for all employees by default or only assigned employees, with optional “show as column even when unassigned.”
- How percentage-based fields should define their base:
  - gross pay.
  - taxable wages.
  - eligible wages excluding tips/bonus.
- Which field types should support annual/per-period caps.
- How to model pass-throughs where one employee’s post-tax deduction becomes another employee’s non-taxable addition.
- Whether company field definitions should wrap/extend `DeductionType` or whether `DeductionType` should be migrated into a more general payroll-field table.

## Design principle

Create the payroll field once at the client/company level, assign it to employees who need it, snapshot it into payroll runs, and report it clearly by field, tax treatment, and employee/employer responsibility.

That gives Cornerstone the QuickBooks-style flexibility they want without making payroll math fragile or breaking MoSa imports.
