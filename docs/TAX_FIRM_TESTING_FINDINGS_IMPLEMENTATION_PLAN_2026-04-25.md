# Tax Firm Testing Findings Implementation Plan

Date: 2026-04-25

## Purpose

This document captures the issues and feature requests found during live testing with the tax firm that will use the software.

It is intended to answer four questions before implementation starts:

1. What was found during testing
2. What the codebase does today
3. What needs to change
4. What order the work should happen in

This is a planning document. It does not represent implemented behavior unless explicitly marked as already fixed.

## Related Documents

- `docs/CLIENT_PORTAL_AND_GUAM_COMPLIANCE_PLAN_2026-04-25.md`
- `docs/CHECK_PRINTING_IMPLEMENTATION_PLAN.md`
- `docs/W2_FILING_OPERATIONALIZATION_PLAN.md`
- `docs/PRODUCTION_FOLLOWUP_ROADMAP_2026-03-29.md`

## Current Status Snapshot

### Already fixed

- Pay rate precision drift where `10.00` could surface as `9.99` / `9.97`
- Pay-period rerun now refreshes stale embedded payroll rates from employee records
- Tips and loans toggle no longer retriggers the page reload loop

### Confirmed bugs or mismatches

- Historical YTD values on checks and pay stubs are not correct when prior pay periods are entered out of order
- `DRT Deposit` currently includes FIT plus FICA-related taxes instead of FIT only
- Form 500 quick-fill quarter logic is based on pay-period end date instead of pay date
- Accountant client assignment editing is currently restricted by workspace context

### Confirmed missing features

- True client portal for client-managed employee onboarding and maintenance
- Required employee address enforcement
- Employee address printed on payroll checks
- Employee list sorting
- Separate deduction for tips already paid out outside payroll
- Native Form 500 generation inside the app
- Sticky headers and sticky first columns on large operational tables
- Configurable report periods such as quarterly, yearly, and custom date range

### Confirmed UX debt

- Numeric fields are difficult to clear because blank values snap back to `0`
- Large lists are harder to read than they should be because zebra striping is not standardized

## Findings By Topic

### 1. Client portal for employee entry, W-4 data, pay setup, and reports

Desired outcome:

- send a client a link to their own workspace
- let them add and update employees
- let them supply W-4 and pay setup details
- optionally let them view reports

Current state:

- the current application is a staff workspace, not a client portal
- login copy says "Use your staff account to continue"
- business APIs live under the admin namespace
- existing external-facing roles are not implemented as a client-safe product surface

Relevant code:

- `web/src/pages/Login.tsx`
- `web/src/App.tsx`
- `api/app/controllers/api/v1/admin/base_controller.rb`
- `api/app/models/user.rb`

Why this matters:

- this is not a permission checkbox
- this requires a product decision about client-safe routes, navigation, approval workflow, and permissions

Implementation notes:

- current fastest workaround is still to invite a scoped staff user and assign only one company
- that workaround is not a clean client portal and is not appropriate if clients will directly touch pay rates, W-4 data, or sensitive reports

Decision needed:

- whether to build a real client portal or continue using scoped staff access as a temporary bridge

### 2. Post-payroll workflow after payroll processing and quarterly returns

Desired outcome:

- define what happens after payroll is calculated and committed
- support Guam-specific payment, filing, and follow-up steps

Current state:

- FIT deposit checks can be auto-created
- 941-GU report generation exists
- W-2GU aggregation exists
- tax sync exists only as a placeholder integration path
- 941-GU still has placeholder lines for deposits, credits, and balance due

Relevant code:

- `api/app/controllers/api/v1/admin/pay_periods_controller.rb`
- `api/app/services/form_941_gu_aggregator.rb`
- `api/app/services/payroll_tax_sync_service.rb`
- `web/src/components/checks/NonEmployeeChecksPanel.tsx`
- `web/src/pages/Reports.tsx`

Why this matters:

- the app is strong at payroll calculation and report preparation
- it is not yet a full operational filing and payment workspace

Operational interpretation:

- FIT withholding should be modeled around Guam DRT / Form 500 / PayGuam
- quarterly withholding workflow should align to GuamTax W-1 processes
- annual wage reporting should align to W-2GU / W-3GU / EFW2 style output expectations

External references reviewed:

- https://www.guamtax.com/efile/w1.html
- https://www.guamtax.com/help/help_w1.html
- https://pay.guam.gov/pg/payments.aspx
- https://pay.guam.gov/pg/HowItWorks.aspx
- https://www.guamtax.com/efile/w2w3.html

Decision needed:

- whether the target is checklist-only operations, a full filing operations workspace, or future direct integrations

### 3. Employee address required and printed on checks

Desired outcome:

- require employee mailing address during setup
- print employee mailing address on payroll checks

Current state:

- employee address fields are optional in the employee model and UI
- W-2GU preflight already treats missing address as a blocking issue
- payroll check rendering prints only employee name on the payee area

Relevant code:

- `api/app/models/employee.rb`
- `web/src/pages/employees/EmployeeForm.tsx`
- `api/app/services/w2_gu_preflight_validator.rb`
- `api/app/services/check_generator.rb`

Why this matters:

- current employee setup allows data that year-end compliance later blocks
- adding address to checks is not just validation work; it is also a PDF layout and check-stock alignment project

Decision needed:

- whether address should be mandatory only for W-2 employees or for all employee records including contractors

### 4. Ability to edit what clients an accountant can see

Desired outcome:

- restore or support direct editing of which clients a scoped accountant can access

Current state:

- assignment editing is restricted when the target user belongs to a different staff workspace
- the UI already explains that some assignments cannot be edited from the current company context

Relevant code:

- `api/app/controllers/api/v1/admin/users_controller.rb`
- `web/src/pages/Users.tsx`

Why this matters:

- this is likely the exact reason testers felt the feature had disappeared
- current behavior is a deliberate guard, not just a broken form

Decision needed:

- whether to remove or relax the workspace guard
- whether assignment editing should be centralized to a single staff workspace instead

### 5. Employee list should be sortable

Desired outcome:

- allow sorting by name, pay rate, status, department, and likely employment type

Current state:

- backend ordering is fixed
- frontend has filters but no sort controls

Relevant code:

- `api/app/controllers/api/v1/admin/employees_controller.rb`
- `web/src/pages/employees/EmployeeList.tsx`

Why this matters:

- current list is functional but not flexible for real operations

Decision needed:

- which sort options need to exist
- whether sort happens server-side, client-side, or both

### 6. Pay rate rounding issue

Desired outcome:

- entered rates should remain exactly what staff entered

Current state:

- this appears fixed
- rate normalization now rounds employee and payroll-item rates to cents
- reruns refresh stale embedded payroll-item rates from current employee data

Relevant code:

- `api/app/models/employee.rb`
- `api/app/models/payroll_item.rb`
- `web/src/pages/employees/EmployeeForm.tsx`
- `api/db/migrate/20260425123000_normalize_stored_pay_rate_precision.rb`

Implementation note:

- this item should be treated as resolved unless new evidence appears

### 7. FIT override should take W-4 into account

Desired outcome:

- align override behavior with the business rule the tax firm expects

Current state:

- FIT is calculated normally using W-4-related fields
- if an override is entered, it completely replaces the normal FIT result

Relevant code:

- `api/app/services/payroll_calculator.rb`
- `web/src/components/payroll/PayrollItemEditModal.tsx`

Why this matters:

- there is a mismatch between what testers expect and what the feature currently means

Decision needed:

- whether override should:
- fully replace FIT
- add to the calculated FIT
- set a minimum FIT floor
- set a target FIT after W-4 logic

### 8. Total DRT should mean FIT only, not EFTPS / FICA totals

Desired outcome:

- everywhere that says DRT should reflect the Guam withholding amount only

Current state:

- pay-period summary currently computes `DRT Deposit` as FIT + employee SS + employee Medicare + employer SS + employer Medicare
- several helper paths still contain legacy EFTPS wording

Relevant code:

- `web/src/pages/PayPeriodDetail.tsx`
- `web/src/components/checks/NonEmployeeChecksPanel.tsx`
- `api/app/controllers/api/v1/admin/reports_controller.rb`

Why this matters:

- this causes operational confusion and can lead to wrong expectations about what is owed to Guam DRT versus federal payment channels

Decision needed:

- define the exact labels for:
- Guam FIT deposit
- employee FICA totals
- employer FICA totals
- total employment taxes

### 9. Gray and white alternating rows on lists

Desired outcome:

- make long operational lists easier to scan

Current state:

- shared table component does not provide zebra striping by default
- some screens use custom tints, but there is no consistent pattern

Relevant code:

- `web/src/components/ui/table.tsx`

Why this matters:

- this is a broad usability improvement that should be done as a shared table style rather than page by page

### 10. Numeric fields should be easier to clear

Desired outcome:

- users should be able to delete the current value without the field instantly snapping to zero

Current state:

- many numeric inputs coerce blank strings to `0` during typing

Relevant code examples:

- `web/src/pages/PayPeriodDetail.tsx`
- `web/src/pages/employees/EmployeeForm.tsx`
- `web/src/components/payroll/PayrollItemEditModal.tsx`

Why this matters:

- this is a repeated data-entry annoyance and slows live payroll editing

Implementation notes:

- this likely needs a shared numeric-input pattern that stores the current text value separately from the parsed numeric value

### 11. Separate column for tips that were already paid out daily

Desired outcome:

- keep taxable reported tips visible
- also allow a separate deduction for tips that were already paid out outside payroll

Current state:

- current tips field is `reported_tips`
- current loan deduction is separate
- there is no field for "tips already paid out"

Relevant code:

- `web/src/pages/PayPeriodDetail.tsx`
- `api/app/services/hourly_payroll_calculator.rb`
- `api/app/services/salary_payroll_calculator.rb`

Why this matters:

- taxable tips and tips already paid outside payroll are not the same thing
- if one field is asked to do both jobs, tax and net-pay math will become ambiguous

Decision needed:

- whether the new field should:
- reduce net pay only
- reduce check amount only
- also print separately on the stub

Compliance note:

- this should be implemented carefully because it touches taxable wage treatment and final check/stub presentation

### 12. Form 500 should use pay date for quarter logic

Desired outcome:

- quick-fill and future filing logic should use pay date quarter, not pay-period end date

Current state:

- Form 500 helper logic currently derives quarter from pay-period end date

Relevant code:

- `web/src/components/checks/NonEmployeeChecksPanel.tsx`
- `web/src/pages/PayPeriodDetail.tsx`

Why this matters:

- this can put a payroll into the wrong quarter for withholding support materials

### 13. Build Form 500 inside the app

Desired outcome:

- generate a Cornerstone-owned Form 500 output instead of relying on a static external PDF link

Current state:

- current app only links to a Form 500 PDF and offers a quick-fill helper
- there is no in-app Form 500 renderer or exporter

Relevant code:

- `web/src/components/checks/NonEmployeeChecksPanel.tsx`
- `web/src/lib/constants.ts`

Why this matters:

- native generation would let the app stay consistent with its own pay-date logic, company data, and calculated FIT totals

Decision needed:

- whether Form 500 output should be:
- browser print view
- generated PDF
- downloadable filled form overlay
- or a structured report that staff key into Guam's own site

### 14. Sticky headers and sticky first column on large lists

Desired outcome:

- keep names and column labels visible when reviewing large payroll tables on zoomed or smaller screens

Current state:

- shared table component supports scrolling but not sticky headers or sticky first column behavior

Relevant code:

- `web/src/components/ui/table.tsx`
- large operational tables in `web/src/pages/PayPeriodDetail.tsx`

Why this matters:

- this is one of the highest-value UX upgrades for payroll review screens

Implementation notes:

- should be solved as a reusable table pattern rather than a one-off patch on one screen

### 15. YTD totals on checks must update correctly when prior pay periods are entered later

Desired outcome:

- each check and stub should show YTD values as of that pay date

Current state:

- current YTD logic sums all reportable committed payroll in the year
- current batch preload logic does the same
- this means historical checks can show totals that include future payroll

Relevant code:

- `api/app/services/check_generator.rb`
- `api/app/models/employee.rb`
- `api/app/controllers/api/v1/admin/pay_periods_controller.rb`
- `api/app/services/payroll_calculator.rb`

Why this matters:

- this is a real payroll correctness issue
- it becomes visible immediately when teams backfill prior periods in a batch

Implementation note:

- this should be treated as a payroll-calculation bug, not a cosmetic report issue

### 16. Reports should be configurable

Desired outcome:

- allow quarterly, yearly, and custom period reporting

Current state:

- reports are currently separate fixed-function panels
- backend tax summary supports year plus optional quarter only

Relevant code:

- `web/src/pages/Reports.tsx`
- `api/app/controllers/api/v1/admin/reports_controller.rb`

Why this matters:

- the current report model is adequate for standard exports but not for operational analysis or client-specific requests

Decision needed:

- whether configurable reports mean:
- custom date ranges only
- custom columns and saved templates
- or a more general report builder

## Phase Breakdown

### Phase 1: Payroll correctness and operational clarity

Status: Implemented

- fix historical YTD logic on checks and pay stubs
- update DRT totals and labels so DRT means FIT only
- switch Form 500 quarter logic to pay date
- align wording that still references legacy EFTPS handling

### Phase 2: Data integrity and payroll setup

Status: Implemented

- require employee addresses where needed
- print employee address on checks
- restore or redesign accountant client-assignment editing
- finalize FIT override semantics

### Phase 3: Day-to-day payroll UX

Status: Implemented

- add sortable employee list
- add zebra striping
- add reusable numeric input behavior that allows blank editing
- add sticky headers and sticky first column support
- add a separate tips-paid-out deduction field

### Phase 4A: Client portal foundation

Status: Implemented on 2026-04-26

- true client portal
- read-only portal reports
- secure document uploads
- audit logging for client actions
- client-safe navigation and routing
- client-facing employee and department maintenance for low-risk fields

### Phase 4B: Approval workflow for payroll- and tax-sensitive changes

Status: Implemented on 2026-04-26

- pay-rate change requests
- W-4 / withholding change requests
- approval queue
- request history and diffs
- admin/manager review surface
- direct application of approved changes with audit trail

### Phase 4C: Native Form 500 output

Status: Implemented on 2026-04-26

- prefilled values
- editable values before export
- printable/downloadable generated PDF
- filled-form overlay using the official Form 500 layout

### Phase 4D: Broader Guam compliance workspace

Status: Deferred

- defer until the real Guam operations workflow is documented in more detail
- do not build this until the tax firm confirms the actual Guam filing/payment workflow, statuses, and evidence requirements

## Recommended Implementation Order

### Phase 1: Payroll correctness and operational clarity

- fix historical YTD logic on checks and pay stubs
- update DRT totals and labels so DRT means FIT only
- switch Form 500 quarter logic to pay date
- align wording that still references legacy EFTPS handling

Reason:

- these are the most operationally risky items and affect real payroll use immediately

### Phase 2: Data integrity and payroll setup

- require employee addresses where needed
- print employee address on checks
- restore or redesign accountant client-assignment editing
- finalize FIT override semantics

Reason:

- these affect setup quality, payroll review, and permissions

### Phase 3: Day-to-day payroll UX

- add sortable employee list
- add zebra striping
- add reusable numeric input behavior that allows blank editing
- add sticky headers and sticky first column support
- add a separate tips-paid-out deduction field

Reason:

- these are high-value workflow improvements but lower risk than payroll correctness work

### Phase 4A: Client portal foundation

- true client portal
- read-only portal reports
- secure document uploads
- audit logging for client actions

Reason:

- this is the first externally facing product slice

### Phase 4B: Approval workflow for sensitive changes

- pay-rate change requests
- W-4 / withholding change requests
- approval queue
- request history and diffs

Reason:

- this lets clients work directly without making payroll-sensitive changes live immediately

### Phase 4C: Native Form 500 output

- prefilled values
- editable values before export
- printable/downloadable generated PDF

Reason:

- this is concrete enough to build now and gives immediate operational value

### Phase 4D: Broader Guam compliance workspace

- later obligations / payments / filings workspace

Reason:

- defer until the real tax-firm workflow is documented in enough detail

Reason:

- these are larger product slices and should be designed deliberately rather than patched into the existing surface

## Open Decisions To Resolve Before Coding

- Whether any payroll-sensitive portal edits should bypass approval in the first release
- Whether staff-requested document checklists should be in the first upload-center release or a follow-up
- Should FIT override replace, add to, or floor the W-4-based withholding amount
- Should DRT-related screens show FIT only, while separate federal tax sections show FICA obligations
- Should the tips-paid-out field reduce net pay only or also appear as a separate check/stub presentation item
- Should native Form 500 output be a printable report, a generated PDF, or a filled-form overlay
- How broad configurable reporting should be after the first read-only portal report release

## Suggested Acceptance Tests

### Payroll correctness

- create pay periods out of chronological order and verify each check stub shows YTD only through that pay date
- verify DRT summary cards and supporting checks use FIT totals only
- verify Form 500 quarter derives from pay date, not end date

### Address and check handling

- verify employee creation fails without required address fields once the rule is enabled
- verify payroll check layout prints employee mailing address correctly on the supported check stock

### Permissions

- verify an accountant's client assignments can be changed from the intended admin context
- verify client-scoped users cannot see unassigned companies
- verify client users cannot reach staff-only routes or APIs
- verify payroll-sensitive portal edits create approval requests instead of updating live values immediately

### Client portal

- verify a client user can sign in and see only portal-safe navigation
- verify a client user can create employees and edit low-risk employee fields directly
- verify a client user can upload documents securely
- verify portal reports are view/download only

### Native Form 500

- verify payroll values prefill the form
- verify users can edit prefilled values before export
- verify the generated PDF is printable and closely matches the official layout

### UX

- verify sortable employee list works across name, department, rate, and status
- verify blanking a numeric field does not immediately force `0` while editing
- verify sticky table header and left column stay visible on narrow and zoomed screens
- verify zebra striping is visually consistent across major operational tables

### Tip handling

- verify reported tips remain taxable
- verify tips already paid out reduce the intended net/check amount without incorrectly reducing taxable wages

## Notes

- The pay rate rounding issue should be considered resolved unless it reappears with new evidence.
- The client portal and broader Guam post-payroll workflow are larger product projects and should not be treated as quick UI fixes.
- The broader Guam compliance workspace is intentionally deferred until the actual Guam workflow is better documented.
- Historical YTD accuracy is the highest-priority payroll correctness issue remaining from this testing batch.
