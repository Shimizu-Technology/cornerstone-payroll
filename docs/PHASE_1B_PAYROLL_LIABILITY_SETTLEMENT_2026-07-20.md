# Phase 1B — Payroll Liability Settlement Ledger

## Purpose

Phase 1A answers **what did committed payroll make payable?** Phase 1B answers **what did the operator actually pay, when, to whom, and with what evidence?** These are deliberately separate records.

The settlement ledger must never recalculate payroll, rewrite a committed liability posting, or infer that an old liability was paid. A settlement is official only when an operator records a payment against exact immutable liability entries.

## Operator workflow

1. Open a committed pay period and review its liability obligations by recipient and category.
2. Confirm or adjust the due date for an obligation group.
3. Record a payment date, method, confirmation number, amount, and optional notes.
4. The service allocates the payment deterministically to the oldest open liability entries in that exact recipient/category group.
5. Attach a receipt or confirmation file. The preserved artifact is size-limited, content-validated, SHA-256 fingerprinted, and immutable.
6. If the payment was entered incorrectly, record an exact reversal with a reason. The original evidence is not edited or deleted.

## Safety invariants

- Phase 1A postings and entries remain immutable and unchanged.
- A payment can only allocate to entries for the same company and pay period.
- A confirmed payment cannot exceed the currently open amount in its selected obligation group.
- Allocation totals always equal the payment amount; reversals exactly negate the source payment and its allocations.
- Concurrent recording is serialized by a pay-period row lock and rechecks open balances inside the transaction.
- Payment, allocation, and evidence rows are immutable.
- Due status is derived from the stored due date and live outstanding balance; paid status is derived from allocation evidence.
- Historical pay periods are never marked paid automatically.

## Reporting and transmittal integration

The pay-period liability response exposes calculated, settled, outstanding, due, and overdue totals plus payment/evidence history. The unified transmittal refreshes calculated tax-obligation items with payment references and evidence-backed settlement status. A transmittal never changes settlement state.

## Out of scope

- Electronic filing or payment submission to Guam DRT, EFTPS, benefit providers, or other authorities.
- Bank-feed matching and automatic settlement.
- Organization-wide multi-period remittance batching. This phase establishes the exact-entry ledger needed for those later workflows.
