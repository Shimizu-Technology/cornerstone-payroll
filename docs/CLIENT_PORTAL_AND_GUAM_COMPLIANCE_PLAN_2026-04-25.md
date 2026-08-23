# Client Portal And Guam Compliance Plan

Date: 2026-04-25

## Implementation update — 2026-08-23

The client portal described below now exists. The April sections remain as historical planning context; they are not the authority for current behavior.

The employee-data boundary implemented for Gate 0 is:

- Client users may directly update basic profile fields: name, email, birth and hire dates, department, address, and phone.
- Pay configuration, employment and tax classification, W-4 and withholding values, retirement settings, contractor identifiers, W-9 state, default earnings and adjustments, wage rates, and SSN replacements require staff approval.
- A client never receives a stored full SSN from the API. The edit form receives last four only; an empty replacement keeps the existing value.
- Full SSN and contractor-EIN replacements are stored only in the encrypted payload of the pending request. Client history redacts them; staff review responses expose masked last four only.
- A client-submitted new worker is saved inactive with zero pay and a pending-approval marker. It cannot enter payroll until staff approves the creation request.
- One pending payroll-sensitive request is allowed per worker. A mixed safe/sensitive submission is atomic: if the sensitive request cannot be created, the safe edits roll back too.
- Approval locks the request and employee, compares the captured original values with current data, and refuses a stale request instead of overwriting a newer staff edit.
- Legacy requests containing a plaintext identifier but no encrypted payload cannot be approved; the client must resubmit the identifier securely.
- Client and staff review pages are routed and linked in their respective navigation.

The authoritative acceptance and release state is tracked in
`docs/GATE_0_TRUST_AND_RELEASE_PLAN_2026-08-23.md`. Code completion does not by itself prove that production migration, deployment, permissions, or operator training is complete.

## Purpose

This document captures what we want to do next in three related areas:

1. A client-facing workflow for entering and maintaining employee information
2. Address requirements and check layout updates
3. Guam-specific post-payroll operations beyond payroll calculation itself

This was created as a planning and discovery document. The dated implementation update above supersedes statements below about whether the portal or approval workflow exists.

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

Decision made:

- build a true client portal
- do not repurpose the staff workspace as the client-facing product

Implications:

- separate client-facing navigation and route guards
- client-safe language and UI states
- a real `client` role or equivalent permission family
- company isolation based on assigned client companies
- a portal-specific API surface rather than exposing the full admin namespace

### B. What clients are allowed to do directly

Decision made:

- clients should be able to use the portal to maintain employees and upload documents directly
- reports in the client portal should be read-only
- payroll- and tax-sensitive edits should use an approval workflow in the first version rather than becoming live immediately

Working model:

Direct edit:

- employee contact info
- employee address
- department and job title
- basic onboarding/profile data
- secure document uploads

Submit for approval:

- pay rate changes
- W-4 / withholding changes
- other fields that directly affect payroll math or tax output

Reason:

- this protects live payroll while still letting clients do real work inside the portal
- it gives Cornerstone a clean audit history and approval trail
- it can be relaxed later if operations prove direct edits are safe

### C. Whether employee self-service is part of the same project

Decision made:

- employee self-service is not part of this portal phase
- this phase is for client users, not individual employees

The current `employee` role can remain a future project and should not be mixed into the client portal MVP.

### D. Guam post-payroll scope

Decision made:

- build native Form 500 support now
- defer the broader Guam compliance operations workspace until the real workflow is better understood

What is in scope now:

- Cornerstone-generated Form 500
- prefilled values from payroll data
- editable values before export
- printable / downloadable PDF
- filled-form overlay using the official layout

What is explicitly deferred:

- broader obligations dashboard
- payment / filing task workflow
- confirmations, evidence, and reconciliation workspace
- integrations beyond the current reporting and export surface

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

Status: Implemented on 2026-04-26

Deliverables:

- invite flow for client-facing users
- portal-safe navigation
- page-level edit restrictions
- create/edit employee workflow
- withholding and pay data workflow
- audit trail for client-submitted changes
- secure document upload center
- read-only client report access
- approval workflow for payroll- and tax-sensitive employee changes

Suggested scope split:

- Phase 3A: client portal foundation
- Phase 3B: secure document uploads and read-only reports
- Phase 3C: approval workflow for payroll- and tax-sensitive employee changes

### Phase 4 - Native Form 500

Status: Implemented on 2026-04-26

Deliverables:

- prefilled Form 500 values based on payroll data
- editable values before export
- generated PDF based on the official layout
- print/download workflow
- filled-form overlay against the official government form

Why next:

- this is well-defined enough to build now
- it delivers immediate operational value without forcing us to guess at the broader Guam workflow

### Phase 5 - Guam compliance operations workspace

Status: Deferred

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

Deferral reason:

- We now know enough to ship the client portal, secure uploads, read-only reports, approval workflow, and native Form 500.
- We do not yet know enough about the tax firm's real Guam operational workflow to safely design the broader obligations / filings / evidence workspace without risking rework.
- This workspace should start only after the tax firm confirms the actual filing/payment steps, due dates, exception handling, and evidence requirements.

Suggested data concepts:

- `tax_obligations`
- `tax_payments`
- `tax_filings`
- `filing_evidence` or attachments
- per-jurisdiction workflow config

### Phase 6 - Exports and integrations

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
- secure document upload center
- read-only report access
- approval workflow for payroll- and tax-sensitive employee changes

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

- define which filing artifacts are generated by the app now
- generate and prefill Form 500
- allow review/edit before print/download
- defer the broader payment / filing workspace until the workflow is documented in more detail

Deferred workflow buckets:

- FIT wage withholding
- Social Security / Medicare related payments
- W-1 quarterly filing
- W-2GU annual filing
- 1099 filing support

---

## Proposed Short-Term Execution Plan

If we wanted to move in the safest order:

1. Finalize the client portal permission model
2. Build the true client portal foundation
3. Add secure uploads and read-only reports
4. Add approval workflow for payroll- and tax-sensitive client edits
5. Build native Form 500 generation
6. Document the broader Guam operations workflow before building that workspace

---

## Recommended Near-Term Tickets

These are good candidates for upcoming planning, not yet implementation.

### Ticket Group 1 - Product design and permissions

- Define client portal role model
- Define client-editable fields
- Keep employee self-service as a later separate project
- Create role/route/page permission matrix

### Ticket Group 1A - Client portal MVP

- portal-safe navigation
- client auth / invites
- client dashboard
- employee management flow
- read-only reports
- secure uploads

### Ticket Group 1B - Approval workflow

- payroll-sensitive change request model
- approval queue
- diff/history view
- audit trail and statuses

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

### Ticket Group 4 - Native Form 500

- import official Form 500 layout
- map payroll values to prefilled fields
- build editable overlay/export flow
- add print/download workflow

### Ticket Group 5 - Guam compliance operations

- Define tax obligation entities and statuses
- Define payment recording model
- Define filing recording model
- Add confirmation/reference capture
- Add receipt/evidence attachment strategy

### Ticket Group 6 - Integration strategy

- Decide whether to support W-2GU EFW2 export
- Decide whether GuamTax / PayGuam integration is desired or whether operator-assisted workflow is enough
- Decide how future `PayrollTaxSync` should relate to Guam filings

---

## Open Questions

These remain unresolved after discovery:

- Should any payroll-sensitive client changes bypass approval in the first release?
- Should document requests from staff be in the first upload-center release or a follow-up?
- Which post-payroll payments are actually done through Guam systems versus external federal systems?
- Do we want the future Guam workspace to track completed payments only, or initiate/support them directly?
- Do we want to support file export for GuamTax / SSA workflows before any API integration?

---

## Recommendation

The most defensible direction is:

- treat client access as a real product surface, not just a role toggle
- use a hybrid portal model where low-risk fields edit directly and payroll-sensitive fields go through approval
- require employee addresses and align daily setup with W-2GU compliance
- build native Form 500 now because it is well-defined
- defer the broader Guam post-payroll operations workspace until the workflow, vocabulary, and records are stable

This sequence reduces rework and keeps the codebase aligned with actual payroll operations instead of mixing legacy assumptions with partial automation.
