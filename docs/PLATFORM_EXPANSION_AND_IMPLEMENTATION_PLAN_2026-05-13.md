# Cornerstone Payroll Platform Expansion And Implementation Plan

Date: 2026-05-13
Status: planning / recommended next phase
Owner: Shimizu Technology / Cornerstone Payroll

## Purpose

Cornerstone Payroll began as a Guam-specific QuickBooks replacement for Cornerstone Tax Services. The application is now strong enough that the next phase should treat it as a platform: a payroll operating system that Cornerstone can use internally and, eventually, make available to other accounting firms.

This document captures:

- what the application already does well
- why the next work should be sequenced carefully
- how to support other accounting firms without leaking data across firms
- how to make check printing easier and safer
- how QuickBooks historical import should work
- how the public homepage, invoice maker, and invoice AI should evolve
- the recommended implementation order

This is a planning document. It intentionally does not make code changes.

## Current Application Position

The application is already more than a payroll calculator. It has the beginnings of a full Guam-native payroll workspace:

- Rails API backend and React/Vite frontend
- Clerk authentication
- user roles: `admin`, `manager`, `accountant`, `client`, `employee`
- company/client switching
- company-scoped employees, departments, pay periods, payroll items, deductions, loans, documents, reports, checks, invoices, and transmittals
- Guam withholding, Social Security, Medicare, Additional Medicare, W-2GU, 941-GU, 1099-NEC, and Form 500 support
- check printing, check numbering, voids, reprints, replacement checks, non-employee checks, and printer profiles
- timecard OCR and time-tracking imports
- client portal surfaces for documents, employee changes, reports, and pay periods
- invoice maker with manual invoices, AI-assisted invoice preview, attachments, PDF generation, and invoice status lifecycle

Important existing documents:

- `docs/QUICKBOOKS_EXIT_AND_HISTORICAL_IMPORT_PLAN_2026-05-10.md`
- `docs/CHECK_PRINTING_IMPLEMENTATION_PLAN.md`
- `docs/TOOLS_INVOICE_AND_GENERAL_TRANSMITTAL_PLAN_2026-05-02.md`
- `docs/CLIENT_PORTAL_AND_GUAM_COMPLIANCE_PLAN_2026-04-25.md`
- `docs/PRODUCTION_FOLLOWUP_ROADMAP_2026-03-29.md`
- `docs/QB_PARITY_CHECKLIST.md`

## Strategic Direction

The next phase should be:

1. Make the platform safe for multiple accounting firms.
2. Make the hardest operator workflow, check alignment, intuitive.
3. Bring QuickBooks history into Cornerstone Payroll safely.
4. Make the product presentable to unauthenticated prospects.
5. Improve invoice creation and invoice documents.

The main principle: do not bolt firm-sharing onto the existing company model. The current `Company` model means payroll client. It should not also mean accounting firm tenant.

## Product Concepts

### Organization

An organization is an accounting firm tenant.

Examples:

- Cornerstone Tax Services
- Another Guam accounting firm interested in using the product

The organization owns:

- staff users
- payroll client companies
- invoice recipients and invoices, once those are made tenant-aware
- import batches
- default branding and firm settings
- organization-level audit visibility

### Company

A company is a payroll client inside an organization.

Examples:

- MoSa's Restaurant
- a Cornerstone payroll client
- a client belonging to another accounting firm

Company-scoped data should remain company-scoped:

- employees
- departments
- pay periods
- payroll items
- checks
- pay stubs
- loans
- payroll reminders
- time tracking sources
- reports
- company check settings

### User Roles

Recommended role direction:

| Role | Scope | Purpose |
|------|-------|---------|
| `super_admin` | all organizations | Shimizu/Cornerstone platform owner. Can create organizations and organization admins. |
| `org_admin` | one organization | Admin for an accounting firm. Can manage that organization's users and payroll client companies. |
| `manager` | assigned companies in one organization | Operational payroll manager. |
| `accountant` | assigned companies in one organization | Payroll/accounting operator for assigned clients. |
| `client` | assigned client company portal | Client-facing user with portal-safe workflows. |
| `employee` | future employee self-service | Employee-facing self-service user. |

The current `admin` role is global in practice. That is acceptable while only Cornerstone uses the app, but it is not safe for outside-firm use.

## Why Organization Tenancy Comes First

The app already has company-level scoping, but outside-firm usage requires firm-level scoping.

Current behavior:

- admins can access all companies
- users belong to a company
- company assignments decide which companies non-admin staff can access
- company switching controls most operational pages

That is close to what Cornerstone needs internally, but not enough for another firm. If a second firm joins, their admin must not see Cornerstone's clients, users, invoices, imports, documents, or audit logs.

Adding organization tenancy later would be more painful because new features like QuickBooks import, invoice web search, and check-layout presets would need to be reworked. Build the tenant boundary first, then build high-value features on top of it.

## Target Tenancy Model

Recommended data model additions:

- `organizations`
  - `name`
  - `slug`
  - `status`
  - firm contact fields
  - branding/settings fields later
- `users.organization_id`
- `companies.organization_id`
- optional `organization_memberships` only if a future user needs access to more than one organization

Recommended first pass:

- keep a single `organization_id` on `users`
- keep a single `organization_id` on `companies`
- migrate all current data into one default organization, likely `Cornerstone Tax Services`
- rename/translate the current `admin` role to `org_admin`, or introduce `super_admin` while preserving existing `admin` semantics behind a migration plan

Recommended authorization rules:

- `super_admin` can see and manage every organization
- `org_admin` can see and manage only their organization
- `manager`, `accountant`, and `client` can only see assigned companies inside their organization
- no endpoint should rely on frontend company switching as the only boundary
- every list endpoint should prove organization scope before returning data

## Check Printing UX Plan

### Current State

The check backend is powerful:

- company-level `check_stock_type`
- company-level `check_offset_x` and `check_offset_y`
- `check_layout_config` JSON overrides
- check alignment PDF
- per-user printer profiles
- top check, bottom check, and First Hawaiian 4-up support

The problem is usability. Operators should not need to edit JSON or reason about X/Y coordinates to fix alignment.

### Desired Experience

Build a visual check layout editor:

- open Check Settings
- choose check stock type
- see a check preview with draggable field boxes
- drag date, payee, amount, amount words, address, memo, and register fields
- use arrow buttons to nudge selected fields by small increments
- use "move whole layout" arrows for global offset
- show rulers or grid marks in inches
- download/print an alignment test from the same screen
- save the calibrated setup as a printer profile
- apply a printer profile to the active client

Advanced JSON should remain available only as a developer/import-export escape hatch.

### Implementation Shape

Do not rewrite check generation first. Instead:

1. Add an API endpoint that returns the resolved layout config for the active company and stock type.
2. Add a frontend editor that manipulates the same `check_layout_config` shape already consumed by the PDF generators.
3. Add a preview endpoint or local preview renderer.
4. Save back through existing check settings.
5. Keep existing PDF generation as the source of truth for actual print output.

## QuickBooks Historical Import Plan

### Key Principle

QuickBooks history should be imported as authoritative historical snapshots. It should not be recalculated by today's Cornerstone Payroll tax calculators.

Existing live import flows are correct for operational imports, but unsafe for historical migration because QuickBooks history can include:

- old tax tables
- manual adjustments
- historical employee setup that no longer matches current setup
- voids and reissued checks
- one-off deductions or benefits
- terminated employees
- historical YTD values that cannot be reconstructed cleanly

### Recommended Import Lane

Build a dedicated QuickBooks import workflow:

- upload source bundle
- inventory files
- parse QuickBooks exports
- normalize to canonical rows
- map employees and companies
- preview validation issues
- reconcile totals
- approve/apply
- lock imported historical periods
- preserve source metadata

Recommended tables:

- `quickbooks_import_batches`
- `quickbooks_import_files`
- `quickbooks_import_rows`
- `external_employee_mappings`
- source metadata fields on imported pay periods/payroll items, or a linked source record table

Minimum source metadata:

- source system: `quickbooks`
- QuickBooks product/source type
- source company name/id if present
- source employee name/id if present
- source paycheck/check id if present
- source check number
- source report name
- source file name
- source row/sheet/cell reference
- source file checksum
- imported by
- imported at

### Import Scope

Start with one representative client and one complete quarter.

Then expand to:

- all 2024-present payroll for that client
- all Cornerstone payroll clients
- older history if needed

Do not start by promising "all clients, all years, all data" in one pass.

## Public Homepage Plan

### Current State

The public-facing route currently sends unauthenticated users to sign in. The login page has some useful positioning copy, but it is still a staff sign-in page.

### Desired Experience

Add a real public homepage:

- route `/` is public
- route `/login` is sign-in only
- authenticated users visiting `/` can be sent to `/app` or a protected dashboard

Homepage content should explain:

- what Cornerstone Payroll is
- why it exists: QuickBooks does not properly support Guam payroll needs
- Guam-native payroll support: W-2GU, 941-GU, Form 500, Guam DRT workflows
- payroll client management for accounting firms
- check printing and reports
- QuickBooks migration support
- who to contact if interested

The page should be professional and trust-building, not a generic SaaS splash page.

## Invoice Maker And Invoice AI Plan

### Current State

The invoice maker already supports:

- recipients
- manual invoices
- invoice line items
- PDF preview/generation
- invoice statuses
- AI chat sessions
- attachment uploads
- structured AI preview before invoice creation

The AI already includes today's date in its prompt. The next improvement is not simply "make it aware of dates"; it is making it better at recipient enrichment and external lookup when staff asks for something like a known Guam organization's address.

### Web Search Direction

If web search is added, use it only for external factual lookup such as:

- recipient mailing address
- public contact information
- public organization name confirmation

Do not use web search for:

- deciding invoice totals
- tax calculations
- payroll calculations
- sensitive client data lookup

Recommended implementation:

- move invoice AI from direct OpenRouter chat completions to an AI service that can use a web search capable API
- store cited sources in preview metadata
- show the sources to staff in the preview UI
- require staff confirmation before saving a new recipient address
- cache verified recipient details in `invoice_recipients`

### Invoice PDF Design Direction

The current PDF is functional but plain. Improve it into a more formal accounting-firm invoice:

- stronger firm letterhead
- cleaner bill-to/from blocks
- professional invoice metadata panel
- better line-item table spacing
- payment/remittance block
- optional prepared-by or contact section
- footer that feels official
- generated invoice snapshot so already-sent invoices do not drift when firm settings change

Stay with Prawn first unless invoice design requirements outgrow it.

## Implementation Order

### Phase 0: Stabilize The Baseline

Purpose: make sure the current app is ready for architectural work.

Tasks:

- run backend and frontend test suites
- confirm current production branch and deployment state
- identify any unmerged work that touches users, companies, check settings, invoices, or imports
- document existing role behavior before changing it

Exit criteria:

- current behavior is understood
- high-risk areas have request/model specs identified
- no surprise local-only changes are blocking tenancy work

### Phase 1: Organization Tenancy Foundation

Purpose: create the tenant boundary required for outside accounting firms.

Tasks:

- add `organizations`
- backfill one default organization for current data
- add `organization_id` to users and companies
- update models and factories
- add `current_organization`
- scope company lists by organization
- define `super_admin` and organization admin behavior
- update user creation/invitation flows
- add authorization specs for cross-organization isolation

Exit criteria:

- Cornerstone still works exactly as before for current users
- a second organization can exist without seeing Cornerstone data
- tests prove cross-organization isolation for core endpoints

### Phase 2: Role And Permission Cleanup

Purpose: make roles consistent for both Cornerstone and outside firms.

Tasks:

- finalize role names and migration path from current `admin`
- ensure `org_admin` can manage only organization users/companies
- ensure `accountant` and `manager` can perform operational payroll work for assigned companies
- ensure staff-global settings are hidden from non-admin staff
- update frontend route guards and sidebar
- add request specs around staff actions

Exit criteria:

- frontend and backend agree on what each role can do
- accountants can do assigned-company payroll work
- admins for one firm cannot see or alter another firm

### Phase 3: Organization Management UI

Purpose: make super admin and org admin workflows usable.

Tasks:

- super admin organization list/create/edit
- create first org admin for an organization
- org admin company/client management
- org admin staff management
- organization-aware company switcher behavior
- clear labels: Organization vs Client Company

Exit criteria:

- super admin can create an outside accounting firm tenant
- that firm's admin can sign in and create/manage client companies
- the user experience no longer overloads "company" to mean both firm and payroll client

### Phase 4: Visual Check Calibration

Purpose: make check printing intuitive and reduce support burden.

Tasks:

- expose resolved check layout config
- create visual editor with draggable fields
- support global offset nudging
- support selected-field nudging
- support print alignment PDF from editor
- save as printer profile
- apply printer profile to active company
- keep JSON advanced mode hidden/collapsed

Exit criteria:

- an operator can fix check alignment without touching JSON
- a printer profile can be reused across client companies
- generated PDFs still use the existing check generators

### Phase 5: QuickBooks Historical Import MVP

Purpose: safely bring in historical payroll without recalculation.

Tasks:

- create import batch/file/row models
- support XLSX/CSV upload
- build parser for first sample QuickBooks export bundle
- map employees
- dry-run preview
- reconciliation summary
- apply locked historical periods/items
- preserve source metadata

Exit criteria:

- one client, one complete quarter imports successfully in dry run
- imported totals reconcile to QuickBooks exports
- imported history appears in normal pay period/report surfaces without recalculation drift

### Phase 6: Public Homepage

Purpose: make the product understandable and credible to interested firms.

Tasks:

- add public `/` route
- move authenticated app entry to protected route if needed
- keep `/login` focused on sign-in
- write clear Guam-native positioning copy
- add contact CTA
- ensure SEO basics remain correct

Exit criteria:

- unauthenticated visitors understand what the app is and who to contact
- sign-in flow remains clean for existing users

### Phase 7: Invoice AI And Invoice PDF Upgrades

Purpose: make invoices smarter and more professional.

Tasks:

- improve invoice PDF visual design
- add generated invoice snapshot if not already present
- add optional web search for recipient lookup
- store source citations
- show source citations in preview
- require staff confirmation for web-found recipient details

Exit criteria:

- invoice PDFs look official enough to send externally
- AI can help find public recipient details without silently inventing them
- staff remains in control before invoice creation

## Suggested First Development Sequence

The first practical work sequence should be:

1. Create a branch for platform tenancy.
2. Add organization model and backfill current data.
3. Add organization scoping to users and companies.
4. Update auth helpers and company switching.
5. Add cross-organization isolation tests.
6. Update user management/invitations.
7. Only after that, start UI work for organization management.

This keeps the riskiest backend boundary work isolated before layering new product workflows on top.

## Phase 1 Technical Checklist

This is the first coding milestone once implementation begins.

### Database

Add migrations for:

- `organizations`
- `users.organization_id`
- `companies.organization_id`
- backfill current users and companies into the default Cornerstone organization
- indexes on `users.organization_id`, `companies.organization_id`, and organization slug/name fields

Keep the migration reversible where practical, but prioritize a clean forward migration because this is a structural platform change.

### Models

Add/update:

- `Organization`
- `User belongs_to :organization`
- `Company belongs_to :organization`
- `Organization has_many :users`
- `Organization has_many :companies`
- factories for organization-aware users and companies

Update access helpers:

- `User#accessible_company_ids`
- `User#can_access_company?`
- add `User#super_admin?` behavior through enum or helper
- add organization-aware admin checks

### Auth And Request Context

Add helpers on `ApplicationController`:

- `current_organization`
- `current_organization_id`
- `require_super_admin!`
- `require_org_admin!`
- organization-aware company resolution

Important rule:

- `X-Company-Id` can select a company only if the current user has access to that company inside the current organization.

### Backend Controllers To Touch First

Start with the core access and management surface:

- `api/app/controllers/application_controller.rb`
- `api/app/controllers/api/v1/auth_controller.rb`
- `api/app/controllers/api/v1/companies_controller.rb`
- `api/app/controllers/api/v1/admin/base_controller.rb`
- `api/app/controllers/api/v1/admin/companies_controller.rb`
- `api/app/controllers/api/v1/admin/users_controller.rb`
- `api/app/controllers/api/v1/admin/company_assignments_controller.rb`
- `api/app/controllers/api/v1/admin/user_invitations_controller.rb`

Then audit the remaining admin/client controllers for any direct `Company.find`, `User.where`, or unscoped global lookup.

### Frontend Surfaces To Touch First

Update:

- `web/src/contexts/AuthContext.tsx`
- `web/src/contexts/CompanyContext.tsx`
- `web/src/components/layout/CompanySwitcher.tsx`
- `web/src/pages/Users.tsx`
- `web/src/pages/Clients.tsx`
- `web/src/App.tsx`
- sidebar labels where "Client Management" and "Company" need clearer meaning

Expected UI behavior after Phase 1:

- existing Cornerstone users still land in the same app experience
- super admins can later be given an organization-management screen
- company switching remains company/client switching, not firm switching
- organization switching is not needed for ordinary firm users

### Tests

Add or update specs for:

- current user auth payload includes organization context
- super admin can see all organizations/companies where intended
- org admin can see only their organization
- org admin cannot see another organization's users
- org admin cannot assign a user to another organization's company
- accountant/manager cannot select a company outside their organization through `X-Company-Id`
- company list never returns companies from another organization

Recommended first spec files:

- `api/spec/models/user_spec.rb`
- `api/spec/models/company_spec.rb`
- `api/spec/models/organization_spec.rb`
- `api/spec/requests/clerk_authentication_spec.rb`
- new request specs for companies, users, and company assignments

### Verification Commands

Run at minimum:

```bash
cd api && bundle exec rspec
cd web && npm run typecheck
cd web && npm run lint
```

If time is tight during a work session, prioritize the request/model specs covering organization isolation before broad UI polish.

## Decisions Needed Before Coding

### Naming

Decide whether the current `admin` becomes:

- `super_admin`, and new firm admins are `org_admin`
- or current `admin` becomes `org_admin`, and selected users become `super_admin`

Recommendation:

- add `super_admin`
- migrate current trusted platform owners to `super_admin`
- convert ordinary current admins to `org_admin` once the org model is in place

### Organization Branding

Decide whether invoices and public contact details should use:

- active company branding
- organization/firm branding
- a separate billing profile

Recommendation:

- payroll checks stay company-branded
- invoices use organization/firm branding by default
- allow recipient-specific or invoice-specific overrides later

### Outside Firm Rollout

Decide whether the first outside firm gets:

- full payroll operations immediately
- limited sandbox/trial access
- guided pilot with one client company

Recommendation:

- guided pilot with one client company after Phase 3
- do not allow production outside-firm payroll before organization isolation tests are in place

## Risk Register

### Cross-Organization Data Leakage

Risk: an outside firm sees Cornerstone data or another firm's data.

Mitigation:

- organization scoping at backend level
- request specs for every high-risk endpoint
- avoid relying on frontend route hiding as authorization

### Role Confusion

Risk: `admin`, `manager`, and `accountant` continue to mean different things in different screens.

Mitigation:

- write and test a permission matrix
- update frontend and backend together
- prefer explicit helpers over scattered role checks

### Historical Import Drift

Risk: imported QuickBooks values get recalculated and no longer match source records.

Mitigation:

- import snapshot mode
- locked historical periods
- reconciliation previews
- source metadata

### Check Calibration Still Feels Technical

Risk: visual editor saves JSON but still exposes too many technical controls.

Mitigation:

- default to drag and nudge controls
- hide JSON
- use real print-test workflow language
- save reusable profiles

### AI Hallucinated Recipient Data

Risk: invoice AI invents or uses stale public information.

Mitigation:

- cite sources
- show staff what was found
- require confirmation
- store verified recipient details only after approval

## Success Criteria For This Phase

This phase is successful when:

- Cornerstone can safely create an organization for another accounting firm
- that firm can manage its own users and client companies without seeing Cornerstone data
- check alignment can be fixed visually without editing JSON
- QuickBooks historical import can bring in one client quarter with reconciliation
- the public homepage clearly explains the Guam-native QuickBooks alternative
- invoices look professional and AI assistance is useful without being risky

## Final Recommendation

Do organization tenancy first. It is the foundation for every other major feature in this plan.

After tenancy is stable, build the visual check calibration tool because it gives immediate operational value and builds on existing backend capability.

Then build the QuickBooks historical import MVP, followed by the public homepage and invoice improvements.

This sequence keeps the product moving while protecting the one thing that matters most if other firms use the app: strict, boring, reliable data isolation.
