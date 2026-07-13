# Tools Expansion Plan: Invoice Maker and General Transmittals

Date: May 2, 2026

> **Planning status (2026-07-12):** The native Invoice Maker and General Transmittal foundations described here were implemented. This document remains the historical build rationale. Future invoice integrity, accounts-receivable, payments, delivery, template, and AI work is governed by the [Invoice Maker Audit and Implementation Plan](INVOICE_MAKER_AUDIT_AND_IMPLEMENTATION_PLAN_2026-07-12.md).

## Purpose

Cornerstone Payroll is becoming the firm's QuickBooks replacement. The core payroll, check printing, reports, Form 500, and pay-period transmittal workflows are already strong enough that the next useful step is to expand the app's general staff tools.

This document captures the plan for two additions:

- A native Invoice Maker tool, based on the separate `other-apps/invoice-maker` prototype
- A General Transmittal Generator tool for one-off checks, quarterly payments, return checks, and other non-pay-period deliveries

The goal is to build these into the existing Rails and React application in a way that supports the accounting firm's real workflow without adding unnecessary operational complexity.

## Current App Context

The app already separates payroll/client work from general staff tools:

- Primary payroll/client navigation includes employees, pay periods, checks/payments, reports, and employee loans.
- The Tools section currently contains Timecard OCR.
- `Checks & Payments` already supports standalone non-employee checks that are not tied to a pay period.
- Pay-period transmittals already exist, but they are intentionally tied to a specific pay period.

Relevant existing areas:

- `web/src/components/layout/Sidebar.tsx` - Tools navigation
- `web/src/App.tsx` - Staff-only routes
- `web/src/pages/ChecksPayments.tsx` - Standalone checks/payments UI
- `api/app/models/non_employee_check.rb` - Standalone and pay-period non-employee checks
- `api/app/models/transmittal.rb` - Existing pay-period transmittal state
- `api/app/services/transmittal_log_pdf_generator.rb` - Existing transmittal PDF generator
- `api/app/controllers/api/v1/admin/reports_controller.rb` - Existing pay-period report and transmittal endpoints

## Decision: Build Native Rails Tools, Do Not Embed FastAPI

The separate invoice-maker app is valuable as a prototype and product reference, but it should not be embedded as a second backend inside Cornerstone Payroll.

The invoice-maker app uses:

- FastAPI
- SQLAlchemy
- PostgreSQL
- WeasyPrint
- Clerk auth
- AI API calls
- Chat session storage
- Invoice PDF generation

Cornerstone Payroll already has equivalent infrastructure in Rails:

- Rails API controllers
- Active Record models and migrations
- PostgreSQL
- Clerk-backed authentication
- Company scoping through `current_company_id`
- Staff/client roles
- PDF generation with Prawn and CombinePDF
- Existing upload/storage services
- Existing React frontend and API client

Rails can support every invoice-maker capability, including AI chat, image/timesheet extraction, invoice previews, PDF generation, email draft generation, history, and statuses. FastAPI is not required for those features.

The recommendation is:

**Use the invoice-maker app as the product spec and workflow reference, but rebuild the feature natively in the existing Rails/React stack.**

This avoids:

- A second backend deployment
- A second auth/session model
- Separate migrations and data ownership
- Separate PDF/runtime dependencies
- Extra API proxying between apps
- More moving parts during and after the QuickBooks cutover

## Tool 1: Native Invoice Maker

### Product Goal

Give staff a fast way to create professional invoices inside Cornerstone Payroll without leaving the app.

This tool should not be tied to a payroll pay period. It should live under Tools because it is a general firm utility, similar to Timecard OCR.

### Important Naming Decision

Avoid naming invoice recipients "clients" in the UI and database.

In Cornerstone Payroll, a "client" already means a payroll company. Using the same word for invoice bill-to parties will confuse operators and future code.

Recommended terminology:

- UI label: `Recipients` or `Bill To`
- Database model: `InvoiceRecipient`

### Minimum Useful Version

The first version should be manual and reliable.

Features:

- Staff-only route: `/tools/invoices`
- Invoice recipient list
- Create/edit recipient details
- Create invoice manually
- Invoice number
- Invoice date
- Optional service period
- Line items with description, quantity, rate, and amount
- Notes/payment terms
- PDF preview/download
- Email subject/body copy
- Status tracking: draft, generated, sent, paid, voided/archived
- Invoice history per active company

### Later AI Version

After the manual workflow is stable, add the AI/chat workflow from the prototype.

Features:

- Chat sessions for invoice creation
- Natural-language requests like "Create an invoice for Spectrio for Jan 1-15"
- Screenshot/timesheet upload or paste
- AI extraction of dates, hours, rates, line items, and totals
- Structured invoice preview before creation
- Preview version history
- Confirm-to-generate PDF
- Auto-generated email body

### Suggested Rails Models

Initial models:

- `InvoiceRecipient`
- `Invoice`
- `InvoiceLineItem`

Possible later models:

- `InvoiceChatSession`
- `InvoiceChatMessage`
- `InvoicePreview`
- `InvoiceTemplate`
- `InvoiceAsset`

Suggested ownership:

- All invoice records should be scoped to `company_id`.
- `created_by_id` and `updated_by_id` should be stored where useful.
- Invoice numbers should be unique per company, not globally.

Suggested fields:

`invoice_recipients`

- `company_id`
- `name`
- `email`
- `address`
- `default_rate`
- `invoice_prefix`
- `payment_terms`
- `template_type`
- `notes`
- `active`

`invoices`

- `company_id`
- `invoice_recipient_id`
- `invoice_number`
- `invoice_date`
- `service_period_start`
- `service_period_end`
- `total_amount`
- `status`
- `notes`
- `email_subject`
- `email_body`
- `pdf_storage_key` or generated PDF metadata
- `created_by_id`
- `updated_by_id`

`invoice_line_items`

- `invoice_id`
- `description`
- `quantity`
- `rate`
- `amount`
- `service_date`
- `position`

### PDF Strategy

Start with Rails-native PDF generation.

Preferred first option:

- Use Prawn, matching the rest of the app's payroll/check/report PDF strategy.

Consider later:

- HTML-to-PDF rendering if invoice templates need more complex design control.

Why start with Prawn:

- Already deployed in the app
- Fewer native dependencies
- Fits existing accounting document patterns
- Easier to keep stable during payroll operations

### AI Strategy

Rails can call AI APIs directly through service objects.

Suggested services:

- `InvoiceAiParserService`
- `InvoiceEmailDraftService`
- `InvoicePreviewBuilder`
- `InvoicePdfGenerator`

The AI service should return structured JSON, not directly create final records. Staff should review a preview first, then confirm generation.

The AI flow should be:

1. Staff sends message and optional images.
2. App stores the message and assets.
3. AI receives the message, prior chat history, recipient context, and image references.
4. AI returns a structured invoice preview.
5. Staff reviews or edits the preview.
6. Staff confirms.
7. App creates the invoice and PDF.

## Tool 2: General Transmittal Generator

### Product Goal

Let staff create transmittals outside of pay periods.

Examples:

- Quarterly return checks
- W-1 balance checks
- SWICA checks
- GRT checks
- Estimated tax payments
- Vendor payments
- One-off client delivery packets
- Manually written checks
- Documents delivered to a client outside payroll processing

This should complement, not replace, the current pay-period transmittal.

### Current Limitation

The existing `Transmittal` model belongs to a `PayPeriod` and validates one transmittal per pay period.

That is correct for payroll packages, but it does not fit one-off or quarterly transmittals.

### Recommended Approach

Build a new general transmittal path instead of forcing the existing pay-period transmittal model to do both jobs immediately.

Suggested route:

- `/tools/transmittals`

Suggested backend:

- New controller under the admin namespace
- New model/table for general transmittal state
- Shared PDF rendering logic where practical

### Suggested Rails Models

Option A, preferred for first implementation:

- `GeneralTransmittal`
- `GeneralTransmittalItem`

Option B, later refactor if useful:

- Generalize pay-period and standalone transmittals into a shared `TransmittalPackage` model with optional `pay_period_id`

Preferred first version is Option A because it is safer. It avoids destabilizing the existing payroll transmittal path during QuickBooks cutover.

Suggested fields:

`general_transmittals`

- `company_id`
- `title`
- `transmittal_date`
- `preparer_name`
- `recipient_name`
- `notes`
- `status`
- `generated_at`
- `created_by_id`
- `updated_by_id`

`general_transmittal_items`

- `general_transmittal_id`
- `source_type`
- `source_id`
- `item_type`
- `title`
- `payable_to`
- `check_number`
- `amount`
- `details`
- `position`

`source_type/source_id` would allow optional linkage to records like `NonEmployeeCheck`.

### Initial Features

The first useful version should support:

- Staff-only route under Tools
- Select active company
- Create a transmittal title/date
- Add standalone checks from `Checks & Payments`
- Add manual items
- Include notes
- Preview/download PDF
- Save generated history

### Important Snapshot Rule

Generated general transmittals should snapshot their item details.

If a linked standalone check is later edited, the old transmittal should still show what was actually delivered at the time. The linked check can remain available for traceability, but the PDF history should not silently change.

This matters for accounting records and client delivery history.

### Relationship To Standalone Checks

The existing standalone check system is a strong foundation.

Standalone checks already support:

- Check type
- Payable to
- Amount
- Check number
- Payment period type
- Tax year/month/quarter
- Payment date
- Confirmation number
- Voucher line items
- Printed/voided status

The general transmittal tool should reuse these records rather than inventing a separate payment object.

## Build Order

### Phase 1: General Transmittal Tool

Priority: highest

Reason:

- It directly supports current accounting firm operations.
- It builds on existing standalone checks.
- It solves one-off check and quarterly payment delivery workflows.
- It is lower risk than AI invoice work.

Deliverables:

- New Rails model/migration
- New API endpoints
- PDF generator
- React page under Tools
- Sidebar link
- Tests for model/controller/generator

### Phase 2: Manual Invoice Maker

Priority: high

Reason:

- Useful as a firm tool.
- Can be built without AI risk.
- Creates the durable data model before chat automation.

Deliverables:

- Invoice recipient CRUD
- Invoice CRUD
- Line item editor
- PDF generator
- Email draft/copy support
- Invoice history and status updates
- Sidebar link

### Phase 3: AI Invoice Assistant

Priority: medium

Reason:

- High value, but should sit on top of a proven manual invoice workflow.
- Avoids mixing AI uncertainty with first-pass accounting record design.

Deliverables:

- Chat sessions/messages
- Image upload support
- AI structured preview generation
- Preview versioning
- Confirm-to-generate flow
- Tests around preview parsing and invoice creation

### Phase 4: Deeper Compliance Connections

Priority: later

Reason:

- The quarterly workflow still needs firm confirmation around W-1, Form 500, Form 941, Schedule B, and SWICA responsibilities.

Possible deliverables:

- Generate transmittals from quarterly compliance checklist items
- Attach filing/payment receipts
- Link Form 500/W-1/SWICA records to general transmittals
- Quarter-end packet generation

## Acceptance Criteria

### General Transmittal Tool

- Staff can create a transmittal without a pay period.
- Staff can include one or more standalone checks.
- Staff can add manual items.
- Generated PDF clearly lists recipient, date, checks/items, amounts, and notes.
- Generated state is saved and does not silently change after linked checks are edited.
- Records are scoped to the active company.
- Client portal users cannot access the tool.

### Manual Invoice Maker

- Staff can create and manage invoice recipients.
- Staff can create invoices with line items.
- Invoice numbers are unique per company.
- Staff can preview/download a PDF.
- Staff can copy an email subject/body.
- Staff can track status from draft to generated to sent/paid, plus void/archive completed records.
- Staff can filter invoice history by status, hide/show archived records, and review the lifecycle timeline for created/generated/sent/paid/voided/archived timestamps.
- Records are scoped to the active organization/company context.
- Client portal users cannot access the tool.

### AI Invoice Assistant

- Staff can create an invoice preview from chat.
- Staff can upload or paste timesheet screenshots.
- AI output is structured and reviewable.
- No final invoice is created until staff confirms.
- The created invoice uses the same invoice models as manual invoices.

## Risks And Guardrails

### Risk: Terminology confusion

Avoid using "client" for invoice recipients. Use `InvoiceRecipient`, `Recipient`, or `Bill To`.

### Risk: Destabilizing payroll transmittals

Do not rewrite the existing pay-period transmittal first. Build general transmittals separately and share rendering only where it is safe.

### Risk: AI creates financial records prematurely

AI should only create previews. Human confirmation should create the invoice.

### Risk: PDF dependency complexity

Start with Prawn. Add HTML-to-PDF only if Prawn cannot reasonably meet invoice template needs.

### Risk: Missing audit/accounting history

Store generated snapshots for transmittals and invoices. Do not rely only on live linked records for documents that were already sent.

## Open Questions

- Should invoice recipients be global across the firm or scoped per active payroll company?
- Should invoices use the active company branding or a separate firm profile?
- Should invoice PDFs be stored persistently or generated on demand from saved snapshots?
- Should general transmittals be shareable in the client portal later?
- Should standalone check vouchers and general transmittals be combined into a single delivery packet?
- What exact quarterly transmittal templates does the firm currently use outside pay periods?

## Recommendation Summary

Build both tools natively in Cornerstone Payroll.

Do not embed FastAPI. Rails can handle the invoice maker, including AI chat, image extraction, PDFs, and history. The separate invoice-maker app should be treated as a prototype/spec, not as a runtime dependency.

Build general transmittals first, then the manual invoice maker, then AI invoice assistance. As of 2026-05-24, the native invoice tool includes manual invoices, AI-assisted previews, generated PDF snapshots, email draft copy, status filters/actions, archive visibility, and lifecycle timeline. Remaining invoice work should focus on richer PDF design, optional persistent PDF storage, and smarter recipient research guardrails.
