# Invoice Center IM-0 + IM-1 Implementation Contract

**Status:** Active implementation contract
**Date:** 2026-07-13
**Parent plan:** [Invoice Maker Audit and Implementation Plan](INVOICE_MAKER_AUDIT_AND_IMPLEMENTATION_PLAN_2026-07-12.md)

## Purpose

This implementation turns the existing Invoice Maker from a document generator with manually assigned statuses into a trustworthy Invoice Center and bounded accounts-receivable subledger.

The immediate user outcome is:

> An authorized business owner can select an invoice-from business such as Shimizu Technology, create invoices or import invoices created elsewhere, preserve the exact issued document, see who owes money, record partial or full payments, and review open, overdue, paid, credited, or uncollectible balances from one auditable workspace.

This is not a general ledger, bank feed, vendor-bill, or accounts-payable implementation.

## Product boundary

### Outgoing invoices and receivables

This phase covers money owed **to** an invoice-from business:

```text
organization
  -> invoice billing profile (the business issuing the invoice)
  -> invoice recipient (the customer owing money)
  -> invoice
  -> immutable issued/imported artifact
  -> delivery history
  -> payments, reversals, and credits
  -> derived balance and aging status
```

### Vendor bills and payables

Documents representing money the business owes to a vendor are bills/accounts payable and are explicitly excluded. They must not be stored as receivable invoices merely because the source document is called an invoice.

## Ownership rules

1. The organization is the authorization boundary.
2. The invoice billing profile is the invoice-from business identity presented to staff.
3. Invoice recipients are organization-owned customer records.
4. IM-0/IM-1 Invoice Center access is restricted to organization administrators. This is the explicit security boundary for organization-wide receivables until a dedicated organization-finance role is introduced; payroll-client-scoped managers and accountants must not mutate another business identity's invoices by changing the active client context.
5. The active payroll client does not silently own, filter, or rebrand invoices.
6. A payroll company may be linked explicitly as optional engagement context.
7. Invoice, recipient, billing-profile, chat, artifact, event, payment, credit, and delivery lookups are scoped by organization on the backend.

This allows Shimizu Technology and Cornerstone Tax Services to be separate invoice-from identities without conflating either identity with the currently selected payroll client.

## Financial lifecycle

Stored base states are:

- `draft` — editable and not yet a receivable;
- `open` — issued and financially frozen;
- `voided` — canceled without deleting its history; and
- `uncollectible` — retained as an unpaid historical receivable.

Reader-facing states are derived from the stored state, due date, valid payments, and issued credits:

- open;
- partially paid;
- paid;
- overdue;
- voided; or
- uncollectible.

Delivery is an event, not a financial state. Archive is a visibility flag, not a financial state. An invoice cannot be marked paid without a valid payment or issued credit that reduces its balance to zero.

## Native and imported invoices

Invoices have an explicit origin:

- `native` — created and issued inside Cornerstone; or
- `imported` — created elsewhere and registered in Cornerstone.

An imported invoice requires:

- invoice-from billing profile;
- recipient;
- invoice number, invoice date, due date/terms, currency, and total;
- exact uploaded PDF or supported image;
- immutable artifact metadata and SHA-256 hash;
- actor and import timestamp;
- optional historically recorded delivery date/channel; and
- a review step before the receivable is created.

Imported artifacts are never re-rendered or rewritten by Cornerstone.

## Immutable evidence

Every issued invoice must retain:

- a structured financial snapshot;
- the exact issued or imported artifact in private durable storage;
- SHA-256 hash, byte size, filename, content type, and storage key;
- template and renderer versions for native PDFs;
- issuer/importer and timestamp; and
- append-only lifecycle events.

Legacy generated invoices are preserved explicitly. Migration may capture their stored snapshot and historical status, but it must not silently regenerate an old invoice from current customer or billing-profile data.

## Accounts-receivable rules

1. Invoice total is immutable after issue.
2. Valid payments increase amount paid; reversed payments do not.
3. Issued credits reduce balance; voided credits do not.
4. Balance due equals invoice total minus valid payments minus valid credits, never below zero.
5. Payment or credit amounts that would over-apply an invoice are rejected.
6. Payment reversal is append-only metadata; payment rows are not deleted.
7. Currency must match the invoice currency.
8. Aging is based on due date and remaining balance.
9. All money arithmetic is decimal-safe and reconciled in integer cents at API/test boundaries.

## Included user experience

- organization-wide Invoice Center dashboard with invoice-from identity visible on each invoice;
- outstanding, overdue, paid, and draft headline totals;
- native invoice creation;
- existing-invoice import and immutable original download;
- searchable/filterable invoice list;
- dedicated detail and financial timeline;
- record/reverse payment flow;
- issue/void/uncollectible/archive controls;
- aging buckets;
- open-invoice and recipient-statement data;
- billing-profile and recipient management; and
- explicit optional payroll-company context.

## Explicit exclusions

- Gmail API delivery and provider-confirmed delivery;
- automatic reminders and scheduled jobs;
- recurring invoices;
- customer portal and online payment processing;
- estimates, quotes, deposits, and milestone billing;
- new hourly/project/tuition PDF templates;
- unrestricted AI actions;
- automatic Guam BPT/GRT tax decisions;
- vendor bills/accounts payable; and
- general-ledger journal posting.

## Migration and backward compatibility

1. Existing invoice numbers remain unchanged.
2. Existing organization ownership remains authoritative.
3. Active payroll-company links become optional context; they are not deleted.
4. Existing `generated` and `sent` invoices become open receivables while preserving timestamps and legacy status.
5. Existing `paid` invoices receive an explicit migration payment equal to their stored total so paid state remains evidence-backed.
6. Existing archived invoices retain archive visibility separately from their financial state.
7. Existing snapshots remain available and are marked legacy when no exact artifact exists.
8. Rollback restores legacy statuses without deleting historical invoice content.

## Required validation

- migration apply, rollback, and reapply;
- organization isolation across all invoice-center routes;
- invoice-number concurrency and invoice-year behavior;
- native issue artifact/hash reproducibility;
- imported artifact integrity and content-type/size enforcement;
- immutable issued financial content;
- valid and invalid lifecycle transitions;
- partial, full, reversed, credited, and over-application accounting;
- due-date and aging boundaries;
- legacy paid and archived preservation;
- PDF multi-page and long-content behavior;
- frontend typecheck, lint, production build, and browser workflows;
- full backend regression suite; and
- local end-to-end creation, import, payment, reversal, aging, and statement checks.

## Follow-on work

After this implementation is stable:

1. **IM-2:** Gmail delivery, reminders, recurrence, scheduled drafts, and communication queues.
2. **IM-3:** branded standard/hourly/project/tuition templates, estimates, receipts, and visual regression coverage.
3. **IM-4/5:** safer AI/source automation and an optional customer/payment portal.
