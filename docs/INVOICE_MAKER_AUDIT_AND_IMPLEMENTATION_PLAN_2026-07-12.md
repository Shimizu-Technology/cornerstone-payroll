# Cornerstone Invoice Maker: Audit and Implementation Plan

**Status:** Active source of truth for Invoice Maker and bounded accounts-receivable work  
**Created:** 2026-07-12  
**Owner:** Shimizu Technology / Cornerstone Tax Services  
**Parent roadmap:** [Payroll, QuickBooks, and Compliance Master Plan](PAYROLL_QUICKBOOKS_COMPLIANCE_MASTER_PLAN_2026-07-11.md)

> **Implementation status (2026-07-13):** IM-0 and IM-1 are being delivered together as the bounded Invoice Center + Accounts Receivable program. The implementation contract is [Invoice Center IM-0 + IM-1](INVOICE_CENTER_IM0_IM1_IMPLEMENTATION_2026-07-13.md). It also makes externally created outgoing invoices importable and trackable while keeping vendor bills/accounts payable explicitly out of scope.

---

## 1. Executive decision

Cornerstone should continue with the native Rails/React Invoice Maker already integrated into this application.

The separate FastAPI `invoice-maker` repository remains valuable as a workflow, template, and usability reference, but it should not return as a second production backend. Doing so would duplicate authentication, tenancy, deployments, migrations, storage, PDF infrastructure, and operational controls.

The current integrated feature is a credible invoice document generator with optional AI drafting. It is not yet a complete invoicing or accounts-receivable system.

The product should now evolve from:

```text
create invoice -> generate PDF -> manually mark sent/paid
```

to:

```text
create draft
  -> review
  -> issue an immutable invoice
  -> deliver and retain evidence
  -> track due date and balance
  -> apply partial/full payments or credits
  -> follow up on overdue balances
  -> preserve the complete audit trail
```

AI should remain an optional drafting layer on top of this deterministic record. It should not issue, send, revise, void, credit, or mark an invoice paid without explicit staff action.

---

## 2. Audit scope and verification

The July 12, 2026 audit covered:

- the standalone `/ShimizuTechnology/invoice-maker` repository;
- its current `fix/chat-retry-and-number-formatting` branch and `main` baseline;
- the historical `other-apps/invoice-maker` reference copy;
- the native Rails models, migrations, controllers, services, routes, and tests;
- the integrated React Invoice Maker and API client;
- organization/company/role boundaries;
- invoice numbering, totals, lifecycle transitions, snapshots, and PDF generation;
- AI previews, recipient resolution, attachments, and confirmation behavior;
- actual local invoice records and rendered PDFs;
- current official product behavior documented by QuickBooks, Xero, Zoho Invoice, FreshBooks, Wave, Stripe, and Square;
- IRS recordkeeping expectations and Guam BPT/GRT context.

Verification completed during the audit:

- integrated invoice backend: `55 examples, 0 failures`;
- integrated frontend: ESLint, TypeScript, and production build passed;
- original frontend: production build passed with five React hook warnings;
- original backend: Python compilation passed, but it has no meaningful automated backend test suite;
- current integrated local data contained four invoices, eight line items, two recipients, two billing profiles, two AI sessions, and thirteen chat messages;
- two local invoices were generated, but only one had the newer immutable JSON snapshot;
- current and legacy generated PDFs rendered successfully as one-page Letter documents.

The local counts above are an audit snapshot, not a permanent product metric.

---

## 3. What exists today

### 3.1 Strong foundations

The integrated Invoice Maker already supports:

- organization-scoped invoice history;
- multiple invoice-from billing profiles;
- bill-to recipient profiles;
- manual draft creation;
- quantity, rate, amount, service date, and service-period fields;
- server-authoritative invoice totals;
- invoice-number uniqueness per billing profile;
- PDF preview and download;
- email subject/body drafting and clipboard copy;
- draft, generated, sent, paid, voided, and archived states;
- lifecycle timestamps;
- protected editing for finalized invoices;
- structured JSON snapshots for newer generated invoices;
- staff-only routes and company-access enforcement;
- AI chat sessions and preview versions;
- image and PDF attachments;
- validation of AI-returned recipient and billing-profile IDs against organization-owned records;
- human confirmation before an AI preview becomes a draft invoice;
- Rails-native Prawn PDF generation;
- focused model, request, service, and PDF tests.

These are meaningful strengths. The feature is not a throwaway prototype.

### 3.2 Original project capabilities worth preserving

The standalone product contains concepts that should be selectively rebuilt in Rails:

- hourly invoices with summary and daily detail;
- task/ticket descriptions;
- project and tuition presentation modes;
- recipient-specific invoice templates;
- copy/duplicate workflows;
- explicit next-number controls;
- mobile-first creation and PWA behavior;
- dedicated history and invoice-detail screens;
- recipient-specific email wording.

The original project should remain a read-only product reference. Its local PDF storage, weaker audit model, separate deployment, and limited automated coverage are not suitable foundations for the integrated product.

### 3.3 Capability comparison

| Area | Original standalone app | Integrated Cornerstone app | Direction |
|---|---|---|---|
| Runtime | FastAPI + React | Rails + React | Keep Rails |
| Ownership | Workspace-based | Organization, company, and staff roles | Standardize on organization/billing profile |
| Billing identities | One business profile | Multiple billing profiles | Keep integrated model |
| Templates | Hourly, project, tuition, client-specific | One generic Prawn invoice | Rebuild controlled presets in Rails |
| Time detail | Hours, date, ticket, description | Generic quantity/rate/date | Add typed time-detail support |
| AI | Rich chat and screenshot flow | Safer structured preview and confirmation | Keep integrated safety boundary |
| Historical evidence | Mutable database + local PDF path | JSON snapshot for newer invoices | Store immutable PDF artifact and hash |
| Tests | Minimal/manual | Good focused backend coverage | Expand browser and visual tests |
| Deployment | Separate app and dependencies | Existing Cornerstone operations | Keep one platform |

---

## 4. Confirmed gaps and risks

### IM-P0-01: ownership and scope are inconsistent

Invoice history, recipients, and billing profiles are organization-scoped. New invoices, AI sessions, and attachment paths also inherit the currently selected payroll company.

This creates confusing behavior:

- invoice history remains organization-wide when the active payroll client changes;
- AI session history can disappear because sessions are company-scoped;
- attachments are stored under the active company even when the invoice is from an organization billing profile;
- the active payroll client silently becomes invoice metadata even when it is unrelated to the bill-to recipient.

Required direction:

```text
organization
  -> invoice billing profile (from identity)
  -> invoice
  -> invoice recipient (bill to)
```

`company_id` should become an optional, explicit source-company or engagement-context link. It should not define invoice ownership merely because that payroll client was selected in the sidebar.

### IM-P0-02: the lifecycle is document-oriented, not accounting-grade

The current model permits generated and sent invoices to return to draft and clears lifecycle timestamps and snapshots. Archive is also modeled as a terminal financial status.

Required direction:

```text
draft -> issued/open -> paid
                    -> voided (if unpaid)
                    -> uncollectible
```

Additional rules:

- issuing freezes financial and recipient content;
- archive is a separate visibility flag, not a financial status;
- corrections create a replacement/revision or credit note;
- issued invoices are not silently rewritten;
- a paid invoice is adjusted through payment reversal/refund/credit workflows, not arbitrary status changes.

### IM-P0-03: there is no receivable or payment ledger

The application does not currently store:

- due date;
- amount paid;
- remaining balance;
- partial payments;
- payment method;
- received date;
- check/ACH/card/reference number;
- payment evidence;
- refunds or reversals;
- customer credits;
- overdue/aging information.

`paid` is therefore a manual label rather than the result of supporting payment records.

Required direction:

- add `InvoicePayment` records;
- derive amount paid and balance due;
- support cash, check, ACH, card, adjustment, and other methods;
- preserve payment reference, received date, recorder, notes, and reversal history;
- calculate current and aging buckets from due date and remaining balance.

### IM-P0-04: generated artifacts are not fully immutable

The JSON snapshot is a good foundation, but:

- legacy generated invoices may have no snapshot;
- those invoices regenerate using current recipient and billing-profile data;
- the exact generated PDF bytes are not stored;
- a future renderer change can produce a different PDF from the same JSON snapshot;
- no document hash or renderer/template version is retained.

Required direction for every issued invoice:

- immutable structured snapshot;
- exact private PDF artifact in R2;
- SHA-256 hash;
- template and renderer version;
- generation actor and timestamp;
- superseded/replacement/credit relationships;
- controlled legacy preservation/backfill policy.

### IM-P0-05: automatic numbering uses the wrong year for backdated invoices

Automatic numbers use `Time.current.year`, not `invoice_date.year`. A backdated invoice can therefore receive the wrong year in its number.

Required direction:

- dedicated sequence per billing profile and invoice year;
- row/advisory locking and database uniqueness;
- optional operator override with conflict validation and audit event;
- preserved gaps rather than renumbering issued invoices.

### IM-P0-06: invoice activity is not fully audited

The invoice controllers do not currently use the application's general `Auditable` concern and do not create a complete invoice event ledger.

Required events include:

- draft created/updated/deleted;
- issued/generated;
- delivered or delivery failed;
- reminder sent;
- payment recorded/reversed;
- credit note issued;
- voided or marked uncollectible;
- archived/restored;
- recipient/billing identity snapshot used;
- AI preview confirmed or manually changed before creation.

### IM-P0-07: delivery is manual and unverifiable

Copying an email draft to Gmail is useful, but marking an invoice sent does not prove:

- which email address received it;
- which exact PDF was attached;
- when it was sent;
- whether delivery failed;
- whether a reminder was sent;
- whether the customer viewed it.

The first improvement can remain staff-controlled: create a Gmail draft or delivery record, snapshot the intended recipient and PDF artifact, and require staff confirmation. Direct sending can follow later.

### IM-P0-08: stored template types are not used by the PDF generator

Recipients support `standard`, `hourly`, `project`, and `tuition`, but the integrated PDF generator renders one generic layout.

Required direction:

- standard professional-services preset;
- hourly/time-detail preset;
- project/installment preset;
- tuition/fixed-payment preset;
- controlled billing-profile branding;
- no unrestricted AI-generated HTML in production.

### IM-P0-09: the current page will not scale

`InvoiceMaker.tsx` is over 2,200 lines and combines history, recipients, billing identities, editing, lifecycle, email, PDF, and AI chat.

Required direction:

- receivables dashboard;
- invoice list with search, status, date, recipient, and balance filters;
- dedicated invoice detail/timeline;
- focused invoice editor;
- recipient directory;
- billing-profile/settings page;
- AI drafting panel that hands off to the same deterministic editor.

### IM-P1-01: recurring and repeat-client workflows are missing

The highest-value operational additions are:

- duplicate/copy last invoice;
- recurring invoice templates;
- scheduled draft creation;
- staff review before automatic delivery;
- recipient-specific defaults;
- unbilled time/expense intake.

### IM-P1-02: customer statements and aging are missing

Staff need to answer:

- who owes money;
- how much is currently due;
- what is overdue;
- what has been paid;
- what reminders were sent;
- which balances need escalation.

Required outputs:

- accounts-receivable aging summary;
- recipient statement;
- open-invoice report;
- payment history;
- collection/reminder queue.

### IM-P1-03: AI attachment controls need hardening

Required controls:

- upload-size enforcement before storage;
- attachment-count limits;
- attachment metadata records;
- MIME/content validation;
- retention and deletion policies;
- external-AI disclosure for uploaded financial/source documents;
- audit visibility into which attachments and prompt version were used;
- no automatic creation, issue, delivery, or payment action by AI.

### IM-P1-04: invoice and payment data need Guam BPT/GRT treatment

Guam BPT/GRT is generally measured against gross receipts and filed monthly. Invoice issuance and cash receipt are related but not identical accounting events.

The system should eventually capture:

- business-activity category;
- taxable, exempt, and excluded receipt treatment;
- payment/receipt date;
- amount received;
- optional visible BPT pass-through policy;
- exemption/supporting-document references;
- monthly reconciliation to GRT reporting.

Do not automatically add 5% to every invoice. Visible pass-through treatment and invoice presentation must be configured per billing profile and approved by Cornerstone tax professionals.

---

## 5. Product requirements

### 5.1 Invoice ownership

```text
Organization
  has many InvoiceBillingProfiles
  has many InvoiceRecipients
  has many Invoices

Invoice
  belongs to InvoiceBillingProfile
  belongs to InvoiceRecipient
  optionally belongs to source Company/engagement
```

All authorization is enforced on the backend. Frontend IDs are never trusted without organization-scoped lookup.

### 5.2 Core invoice facts

An invoice should preserve:

- invoice number and sequence year;
- invoice date;
- due date and terms;
- currency;
- purchase-order/customer reference;
- service period;
- billing-profile snapshot;
- recipient/contact snapshot;
- line items and position;
- subtotal, discounts, credits, tax/pass-through presentation, total, paid, and balance;
- status and archive visibility;
- issued PDF artifact/hash/template version;
- creator, issuer, delivery, and revision history.

### 5.3 Payments and credits

Recommended records:

```text
invoice_payments
  organization_id
  invoice_id
  amount
  received_on
  payment_method
  reference_number
  notes
  recorded_by_id
  reversed_at / reversed_by_id / reversal_reason

invoice_credit_notes
  organization_id
  invoice_id
  credit_number
  issue_date
  reason
  total_amount
  snapshot / artifact / hash
```

Invoice balance is derived from immutable invoice total, valid payments, and issued credits.

### 5.4 Delivery and reminders

Recommended records:

```text
invoice_deliveries
  invoice_id
  artifact_id/hash
  recipient email snapshot
  channel
  provider/message id
  attempted/sent/delivered/failed/viewed timestamps
  failure reason

invoice_reminders
  invoice_id
  rule/template
  scheduled_at
  sent_at
  delivery linkage
```

### 5.5 Recurring templates

Recurring templates should create drafts, not silently issue financial records, until the workflow is proven and the billing profile explicitly opts into automatic issue/delivery.

Required schedule facts:

- frequency and interval;
- next run date;
- service-period rule;
- due-date rule;
- default line items;
- recipient and billing profile;
- review/auto-issue policy;
- active/paused/end date;
- last generated invoice.

### 5.6 AI boundary

AI may:

- parse staff instructions;
- extract candidate dates, hours, rates, and descriptions;
- match organization-owned recipients and billing profiles;
- draft email copy;
- create a reviewable structured preview;
- explain changes between preview versions.

AI may not independently:

- choose an unverified recipient identity;
- invent rates or billable work;
- issue/finalize an invoice;
- send an invoice;
- record a payment;
- void or credit an invoice;
- decide BPT/GRT treatment;
- alter an issued invoice.

---

## 6. Implementation program

### Phase IM-0: trustworthy invoice foundation

**Goal:** Make issued invoices immutable, correctly scoped, and auditable before expanding automation.

Deliverables:

1. Standardize ownership on organization and billing profile.
2. Make payroll-company/engagement linkage optional and explicit.
3. Add due date, currency, customer reference, and archive flag.
4. Replace lifecycle transitions with draft/issued/open/paid/void/uncollectible semantics.
5. Add locked per-profile/per-year numbering sequences based on invoice date.
6. Store immutable issued snapshot, exact PDF, hash, and renderer/template version.
7. Add invoice event/audit history.
8. Add revision/replacement and credit-note foundations.
9. Preserve/backfill legacy generated invoices without silently changing their historical content.
10. Split the current monolithic UI into list, detail, editor, recipient, and billing-settings components.
11. Add long-content, multi-page, lifecycle, concurrency, tenancy, and browser tests.

Exit gate:

- active payroll-client selection cannot change invoice ownership or history;
- an issued invoice cannot be silently edited or regenerated differently;
- automatic numbers use the invoice year and remain unique under concurrency;
- every issued invoice has an artifact, snapshot, hash, actor, and event history;
- legacy generated invoices have an explicit preserved/legacy status;
- tenant-isolation tests cover all invoice, recipient, profile, chat, attachment, artifact, payment, and event routes.

### Phase IM-1: accounts receivable

**Goal:** Make the feature useful for tracking money owed and received.

Deliverables:

1. Invoice payment and reversal ledger.
2. Partial/full payment support.
3. Amount paid and remaining balance.
4. Due/overdue calculations.
5. Aging buckets and receivables dashboard.
6. Recipient statements and open-invoice report.
7. Payment receipts.
8. Credits, refunds, and uncollectible handling.
9. BPT/GRT receipt metadata and reconciliation fields.
10. CSV/PDF exports for accounting review.

Exit gate:

- invoice status and balance derive from evidence-backed records;
- partial, full, reversed, and credited scenarios reconcile exactly;
- staff can identify every open and overdue balance;
- recipient statements tie to invoice/payment history;
- no invoice can be marked paid without supporting payment or credit records.

### Phase IM-2: repeatable staff workflow

**Goal:** Reduce repetitive work and improve collections without removing staff control.

Deliverables:

- duplicate/copy last invoice;
- recurring templates and scheduled drafts;
- delivery records and Gmail draft integration;
- manual reminder workflow;
- configurable automatic reminder schedules;
- recipient contacts and communication history;
- bulk review/send queues;
- unbilled time/expense intake from supported source systems.

Exit gate:

- a repeat client can be billed in a small number of reviewed actions;
- staff can prove what was delivered and when;
- reminders stop when the invoice is paid/credited/voided;
- recurring jobs are idempotent and cannot create duplicate invoices.

### Phase IM-3: professional documents and billing modes

**Goal:** Produce polished documents for the firm's actual billing scenarios.

Deliverables:

- configurable logo, brand color, legal/remittance fields, and footer;
- standard professional-services template;
- hourly/time-detail template with task/ticket rows;
- project/installment template;
- tuition/fixed-payment template;
- estimates/quotes and conversion to invoice;
- deposits and milestone schedules;
- credit-note and payment-receipt documents;
- stored artifact preview and download;
- multi-page visual regression fixtures.

### Phase IM-4: safer AI and source automation

**Goal:** Make AI materially faster without weakening the financial record.

Deliverables:

- strict structured response schema;
- decimal-safe money values;
- prompt/model/version audit metadata;
- attachment limits, metadata, retention, and disclosures;
- time-tracking and source-document extraction;
- cited recipient enrichment from public sources;
- staff confirmation before saving enriched data;
- preview-difference explanations;
- unsupported/ambiguous requests that fail closed.

### Phase IM-5: customer portal and payment integrations

**Goal:** Let recipients securely view balances and pay while preserving reconciliation.

Deliverables:

- secure recipient invoice page;
- exact issued-PDF download;
- balance and payment history;
- optional payment provider after confirming Guam support, cost, settlement, and dispute behavior;
- signed webhook processing and idempotency;
- settlement/fee/refund reconciliation;
- recipient comments or disputes;
- firm-level collection reporting.

---

## 7. Relationship to the larger QuickBooks roadmap

This plan does not authorize a general-ledger build and does not change the priority of payroll and employer compliance in the parent master plan.

It creates a bounded Invoice/AR subledger that is useful now and can later post into the optional accounting kernel.

Recommended program relationship:

- close the remaining operational evidence for Payroll Phase 0;
- continue Payroll Phase 1 and the payroll liability/deposit foundation;
- implement Invoice IM-0 as a focused integrity project;
- implement Invoice IM-1 if Cornerstone wants the current Invoice Maker to replace real receivables tracking;
- keep invoice events posting-ready for a future general ledger;
- do not wait for full Phase 6 accounting to make invoices trustworthy;
- do not market invoice/AR work as full QuickBooks accounting parity.

The future accounting kernel should consume invoice events rather than own invoice workflow logic:

```text
invoice issued -> debit Accounts Receivable / credit Revenue
payment applied -> debit Cash or Undeposited Funds / credit Accounts Receivable
credit issued -> debit Contra Revenue or configured account / credit Accounts Receivable
```

Those postings are future behavior and require an approved chart-of-accounts and journal design. The Invoice Maker should preserve enough structured facts to support them later.

---

## 8. Market baseline and official references

Serious invoice products consistently provide due dates, balances, partial/offline payments, reminders, recurring invoices, statements, credits, and payment/communication history.

- [QuickBooks: create invoices](https://quickbooks.intuit.com/learn-support/en-us/help-article/invoicing/create-invoices-quickbooks-online/L7gSzvCld_US_en_US)
- [QuickBooks: automatic invoice reminders](https://quickbooks.intuit.com/learn-support/en-us/help-article/invoicing/send-invoice-reminders-automatically-manually/L84cQjpxo_US_en_US)
- [QuickBooks: recurring transactions](https://quickbooks.intuit.com/learn-support/en-us/help-article/recurring-transactions/create-recurring-transactions-quickbooks-online/L3WoKX2R8_US_en_US)
- [Xero invoicing and accounts receivable](https://www.xero.com/us/accounting-software/send-invoices/)
- [Zoho Invoice features](https://www.zoho.com/in/invoice/features/)
- [Wave invoicing](https://www.waveapps.com/invoicing)
- [Stripe invoice lifecycle](https://docs.stripe.com/invoicing/overview)
- [Stripe credit notes](https://docs.stripe.com/invoicing/dashboard/credit-notes)
- [Stripe partial payments](https://docs.stripe.com/invoicing/partial-payments)
- [Square deposits and payment schedules](https://squareup.com/help/us/en/article/6581-request-deposits-with-square-invoices)
- [IRS business recordkeeping](https://www.irs.gov/businesses/small-businesses-self-employed/recordkeeping)
- [GuamTax GRT requirements](https://www.guamtax.com/help/help_grt.html)
- [Guam Public Law 27-41 visible pass-through regulation](https://www.guamtax.com/info/GPL27-41_Regulation.pdf)
- [2025 Guam BPT invoice-itemization bill veto communication](https://guamlegislature.gov/38th_Guam_Legislature/Mess_Comms_38th/Doc.%20No.%2038GL-25-0745.pdf)

---

## 9. First implementation backlog

Recommended initial tickets:

1. **CPR-IM-001:** Standardize invoice, chat, attachment, and recipient ownership on organization/billing-profile scope.
2. **CPR-IM-002:** Redesign invoice lifecycle and make archive orthogonal to financial status.
3. **CPR-IM-003:** Add due date, currency, customer reference, and issued/open semantics.
4. **CPR-IM-004:** Build locked invoice-date-year numbering sequences.
5. **CPR-IM-005:** Store immutable PDF artifacts, hashes, renderer versions, and legacy preservation state.
6. **CPR-IM-006:** Add complete invoice event/audit history.
7. **CPR-IM-007:** Add replacement/revision and credit-note foundations.
8. **CPR-IM-008:** Split Invoice Maker into receivables list, invoice detail, editor, directory, and settings components.
9. **CPR-IM-009:** Add `InvoicePayment`, reversals, partial payments, and derived balance/status.
10. **CPR-IM-010:** Add overdue calculations, aging dashboard, open-invoice report, and recipient statements.
11. **CPR-IM-011:** Add duplicate/copy-last and recurring draft templates.
12. **CPR-IM-012:** Add delivery/reminder records and Gmail draft workflow.
13. **CPR-IM-013:** Rebuild hourly/project/tuition template concepts with visual regression tests.
14. **CPR-IM-014:** Add AI attachment governance, strict schemas, and prompt/model audit metadata.
15. **CPR-IM-015:** Add BPT/GRT receipt classification and monthly reconciliation fields after professional approval.

Recommended first delivery batch: `CPR-IM-001` through `CPR-IM-008`. Do not begin online payments or deeper AI automation before that batch passes its exit gate.

---

## 10. Completion language

Cornerstone may call the feature a **professional invoice maker** when:

- invoice ownership is consistent;
- numbering is deterministic and year-correct;
- issued invoices are immutable and artifact-backed;
- due dates, delivery, audit history, and corrections are reliable;
- all supported templates pass visual and multi-page validation.

Cornerstone may call it **accounts receivable** when:

- payments, credits, balance due, overdue status, aging, and statements reconcile;
- paid status is derived from evidence;
- delivery and reminder history are retained.

Cornerstone should not call it a **complete QuickBooks accounting replacement** until the separate accounting-kernel exit gates in the parent master plan are satisfied.

---

## 11. Immediate next action

Implement Invoice Phases IM-0 and IM-1 together as one focused Invoice Center + Accounts Receivable branch/PR program, beginning with ownership, lifecycle, numbering, immutable artifacts, audit events, legacy preservation, external invoice import, and evidence-backed balances.

Before implementation, confirm two business decisions with Cornerstone:

1. Are Shimizu Technology and Cornerstone Tax Services both valid invoice-from identities under the same organization, and should the active payroll client ever affect invoice ownership?
2. Which currently generated invoices have already been sent externally and therefore must be preserved as historical issued artifacts before any lifecycle migration?
