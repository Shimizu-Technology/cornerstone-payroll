# Client Portal And Guam Compliance Plan

Date: 2026-04-25

## Purpose

This document captures what we want to do next in three related areas:

1. A client-facing workflow for entering and maintaining employee information
2. Address requirements and check layout updates
3. Guam-specific post-payroll operations beyond payroll calculation itself

This is a planning and discovery document. It does not represent implemented behavior.

Related follow-up document:

- `docs/TAX_FIRM_TESTING_FINDINGS_IMPLEMENTATION_PLAN_2026-04-25.md`

---

## Desired Outcomes

### 1. Client-facing employee setup and maintenance

We want a workflow where a payroll client can be sent a link and can:

- enter new employee information
- update employee personal information
- supply W-4 and withholding information
- supply pay information
- possibly view reports

### 2. Employee address enforcement and check behavior

We want:

- employee addresses to be required
- checks to use the employee's address, not just the employee name
- the employee setup flow to enforce the same address requirements that year-end compliance already expects

### 3. Guam-specific post-payroll workflow

We want a clearer operational plan for everything after payroll is calculated and committed, including:

- FIT withholding payment flow
- Guam DRT / Form 500 workflow
- quarterly return workflow
- annual W-2GU filing workflow
- future filing and payment integrations where appropriate

---

## Current State Summary

### The app today is a staff workspace, not a client portal

Current behavior in code:

- Login says "Use your staff account to continue."
- Core business endpoints live under `/api/v1/admin/...`
- The existing `employee` role is described as future self-service, not an implemented portal role
- Staff users are modeled as global staff accounts with company assignments, not as client-owned tenant users

Relevant code:

- `web/src/pages/Login.tsx`
- `api/app/controllers/api/v1/admin/base_controller.rb`
- `web/src/pages/Users.tsx`
- `api/app/controllers/api/v1/admin/users_controller.rb`

Implication:

- A true client portal is a product and architecture project, not a small permission tweak.
- The fastest operational workaround today would be to invite a client contact as a scoped `manager` or `accountant`, but that still uses the staff UI and is not a clean client-facing product.

### Employee addresses are optional in setup, but required for year-end compliance

Current behavior in code:

- `Employee` validates payroll and tax fields, but does not require address fields
- the employee form UI does not require address fields
- W-2GU preflight already treats missing employee addresses as blocking

Relevant code:

- `api/app/models/employee.rb`
- `web/src/pages/employees/EmployeeForm.tsx`
- `api/app/services/w2_gu_preflight_validator.rb`

Implication:

- There is already a compliance mismatch between daily data entry and year-end readiness.
- Requiring addresses is directionally correct and aligns with existing W-2GU validation.

### Payroll checks do not currently print employee addresses

Current behavior in code:

- payroll checks print the employee name in the payee area
- no employee mailing address is rendered on the payroll check face

Relevant code:

- `api/app/services/check_generator.rb`

Implication:

- If the business requirement is "checks should use the employee's address," the check layout will need to change, not just the employee validations.
- We need to confirm whether "use the address" means:
  - print the employee mailing address on the check face, or
  - use the address only in supporting documents and mailing workflows, or
  - both

### Guam reporting exists, but filing and payment workflows are not complete

Current behavior in code:

- FIT tax deposit checks can be auto-created on payroll commit
- those checks are now created payable to `Treasurer of Guam`
- the UI contains Form 500 helper links
- 941-GU and W-2GU reporting data exists
- 941-GU still treats deposits, credits, and balance calculations as placeholders
- tax sync is only a placeholder for a future external integration

Relevant code:

- `api/app/controllers/api/v1/admin/pay_periods_controller.rb`
- `api/app/services/form_941_gu_aggregator.rb`
- `web/src/components/checks/NonEmployeeChecksPanel.tsx`
- `web/src/components/reports/ReportsDownloadPanel.tsx`
- `docs/PRODUCTION_FOLLOWUP_ROADMAP_2026-03-29.md`

Implication:

- The app is currently strong at payroll calculation and filing-prep artifacts.
- It is not yet a complete filing and payment operations system.

---

## Guam Research Summary

External Guam sources reviewed on 2026-04-25 indicate:

- GuamTax supports W-1 employer quarterly return e-filing
- GuamTax W-1 flow mentions associated Form 500 payment retrieval
- PayGuam supports `500WAGE` payments for withholding on wages
- PayGuam describes payments as going to the Treasurer of Guam
- GuamTax supports W-3/W-2GU e-filing and points to SSA EFW2 format

Useful references:

- https://www.guamtax.com/efile/w1.html
- https://www.guamtax.com/help/help_w1.html
- https://pay.guam.gov/pg/payments.aspx
- https://pay.guam.gov/pg/HowItWorks.aspx
- https://www.guamtax.com/efile/w2w3.html

Operational interpretation:

- FIT withholding on wages should be modeled around Guam DRT / Form 500 / PayGuam, not around legacy EFTPS-only wording
- W-1 quarterly filing should be treated as a GuamTax workflow with reconciliation to recorded Form 500 payments
- W-2GU should eventually support an export or integration path compatible with GuamTax's W-2GU filing expectations

---

## Known Inconsistencies To Clean Up

### Legacy EFTPS wording still exists in parts of the app

Newer code paths:

- FIT tax deposit checks are created payable to `Treasurer of Guam`
- check settings copy says remit via Guam DRT Form 500

Older or mixed wording still present:

- some UI fallback logic still checks for `EFTPS - Federal Income Tax`
- transmittal notes still assume EFTPS for Social Security and Medicare

Relevant code:

- `api/app/controllers/api/v1/admin/pay_periods_controller.rb`
- `web/src/pages/CheckSettings.tsx`
- `web/src/pages/PayPeriodDetail.tsx`
- `web/src/components/checks/NonEmployeeChecksPanel.tsx`
- `web/src/components/reports/ReportsDownloadPanel.tsx`

Implication:

- Before building more automation, we should lock down the exact Guam operating model for each payment type and make the language consistent everywhere.

---

## Product Decisions Required

These decisions should be made before implementation starts.

### A. What "client portal" actually means

We need to choose between:

1. A true client portal
- separate client-facing navigation and permissions
- client-safe language and UI
- likely a new role or role family
- separate route guards and page states

2. A scoped staff-style portal for clients
- reuse current app
- invite client contacts as `manager` or `accountant`
- assign only their company
- cheaper and faster, but lower product polish and more permission risk

Recommended direction:

- If clients will touch pay rates, tax setup, or reports directly, build a true client portal rather than repurposing the staff workspace.

### B. What clients are allowed to do directly

We need to define whether clients can:

- create employees
- edit employees
- set pay rates
- set W-4 or W-4-like withholding fields
- upload employee documents
- view payroll reports
- download pay stubs
- approve changes

Recommended direction:

- Separate "submit" from "approve" for sensitive fields if Cornerstone wants review before payroll impact.

### C. Whether employee self-service is part of the same project

The current `employee` role suggests a future self-service portal, but that is distinct from a client portal.

We need to decide whether:

- client portal comes first and employee self-service is separate later, or
- both are part of one broader external-access initiative

Recommended direction:

- Treat employee self-service as a separate phase after client portal fundamentals are stable.

### D. Guam post-payroll scope

We need to choose the target product level:

1. Checklist and reporting only
- reports
- links
- manual confirmations

2. Operations workspace
- payment tasks
- filing tasks
- confirmations
- receipt uploads
- statuses
- audit trail

3. Full integration
- export files
- API integrations
- external filing/payment sync

Recommended direction:

- Build an operations workspace first.
- Do not jump directly to external integration until the workflow and data model are stable.

---

## Recommended Build Order

### Phase 1 - Lock the product model

Deliverables:

- permission matrix for admin / manager / accountant / client / employee
- decision on whether "client portal" is separate from staff workspace
- decision on which fields clients can edit directly versus submit for review
- decision on whether reports are visible to clients, and which ones

Why first:

- The current codebase still reflects an in-progress permission model cleanup.
- Building UI first without a locked policy model will create rework.

### Phase 2 - Address compliance and check layout

Deliverables:

- require `address_line1`, `city`, `state`, and `zip` for employees where needed
- add migration/backfill strategy for existing employees with incomplete addresses
- update employee form validation and import validation
- update payroll check layout if the business wants mailing address printed on checks
- verify no layout regressions on real stock

Why second:

- This is the smallest, clearest improvement.
- It also resolves an existing mismatch between operations and W-2GU readiness.

### Phase 3 - Client-facing onboarding and maintenance

Deliverables:

- invite flow for client-facing users
- portal-safe navigation
- page-level edit restrictions
- create/edit employee workflow
- withholding and pay data workflow
- audit trail for client-submitted changes

Suggested scope split:

- Phase 3A: client can create and edit employee records
- Phase 3B: client can submit pay and withholding changes
- Phase 3C: client can view approved reports

### Phase 4 - Guam compliance operations workspace

Deliverables:

- obligations dashboard for:
  - FIT on wages
  - FICA-related payments if still handled externally
  - quarterly return tasks
  - annual filing tasks
- payment records
- filing records
- confirmation numbers
- notes and attachments
- due dates and statuses
- reconciliation against payroll totals

Suggested data concepts:

- `tax_obligations`
- `tax_payments`
- `tax_filings`
- `filing_evidence` or attachments
- per-jurisdiction workflow config

### Phase 5 - Exports and integrations

Deliverables:

- W-2GU EFW2 export if needed
- GuamTax / PayGuam assisted workflows or data exports
- future Cornerstone external filing ingest integration

Why last:

- Current tax sync is explicitly still a placeholder
- operational workflow should be stable before integration contracts are built

---

## Area-By-Area Requirements

### Client Portal Requirements

Minimum requirements:

- invitation and account lifecycle for external client contacts
- company isolation
- safe default permissions
- separate nav and UX copy from internal staff
- audit trail for all external edits
- read-only and approval states where applicable

Nice-to-have:

- branded client-facing invite and login copy
- task checklist for onboarding
- guided employee setup

### Employee Address Requirements

Minimum requirements:

- require `address_line1`, `city`, `state`, `zip`
- keep `address_line2` optional
- validate for manual entry, bulk import, and future client portal flows
- surface missing-address counts in operational dashboards

Migration concern:

- existing records may fail validation after enforcement
- we will need a rollout plan:
  - report current incomplete records
  - backfill before hard enforcement, or
  - soft-enforce on create/update first, then hard-enforce later

### Check Address Requirements

Need business clarification:

- print employee address on payroll checks, yes or no
- if yes, where on the stock layout
- whether this applies to:
  - payroll checks only
  - non-employee checks too
  - pay stubs

Engineering note:

- this is a PDF layout change and requires visual verification on actual check stock
- it is not only a form validation change

### Guam Post-Payroll Requirements

Minimum requirements:

- define which payment types are inside scope
- define which filing artifacts are generated by the app
- record what was paid, when, how, and with which confirmation/reference
- reconcile recorded payments to payroll-derived liabilities
- preserve operator notes and evidence

Likely workflow buckets:

- FIT wage withholding
- Social Security / Medicare related payments
- W-1 quarterly filing
- W-2GU annual filing
- 1099 filing support

---

## Proposed Short-Term Execution Plan

If we wanted to move in the safest order:

1. Finalize the permission model and decide portal strategy
2. Enforce employee address requirements and clean up existing records
3. Decide whether payroll checks must print the employee address
4. Build a Guam compliance operations data model before any external integrations
5. Only then decide which GuamTax / PayGuam / external filing integrations are worth implementing

---

## Recommended Near-Term Tickets

These are good candidates for upcoming planning, not yet implementation.

### Ticket Group 1 - Product design and permissions

- Define client portal role model
- Define client-editable fields
- Define employee self-service separation
- Create role/route/page permission matrix

### Ticket Group 2 - Address enforcement

- Audit all employees with incomplete address data
- Add address requirements to employee model and forms
- Add address requirements to bulk import preview/apply
- Decide whether contractor address requirements differ

### Ticket Group 3 - Check layout

- Design address-on-check layout
- Prototype PDF coordinates
- Validate against live stock
- Confirm no overlap with amount/payee/memo fields

### Ticket Group 4 - Guam compliance operations

- Define tax obligation entities and statuses
- Define payment recording model
- Define filing recording model
- Add confirmation/reference capture
- Add receipt/evidence attachment strategy

### Ticket Group 5 - Integration strategy

- Decide whether to support W-2GU EFW2 export
- Decide whether GuamTax / PayGuam integration is desired or whether operator-assisted workflow is enough
- Decide how future `PayrollTaxSync` should relate to Guam filings

---

## Open Questions

These remain unresolved after discovery:

- Do we want a true client portal or just scoped access into the current app?
- Should clients be able to directly edit pay rates?
- Should clients directly edit withholding values, or submit them for approval?
- Does "checks use employee address" mean print the address on the paper check face?
- Which post-payroll payments are actually done through Guam systems versus external federal systems?
- Do we want the app to track completed payments only, or initiate/support them directly?
- Do we want to support file export for GuamTax / SSA workflows before any API integration?

---

## Recommendation

The most defensible direction is:

- treat client access as a real product surface, not just a role toggle
- require employee addresses and align daily setup with W-2GU compliance
- treat Guam post-payroll work as an operations workflow first
- add integrations only after the workflow, vocabulary, and records are stable

This sequence reduces rework and keeps the codebase aligned with actual payroll operations instead of mixing legacy assumptions with partial automation.
