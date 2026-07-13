# Phase 1A: Payroll Liability Foundation

**Status:** Implementation candidate on `codex/phase-1-payroll-liability-foundation`

**Date:** 2026-07-13

## Purpose

Phase 0 made committed paycheck calculations traceable by preserving their tax bases, tax-year configuration, and W-4 evidence. Phase 1A begins the operational accounting layer needed to replace QuickBooks for payroll.

The purpose of this PR is to answer, from immutable committed payroll facts:

- what obligations did this payroll create;
- who is expected to receive each obligation;
- on what liability date was it created;
- was the obligation reversed or replaced by a controlled correction;
- does a historical payroll still require an explicit ledger backfill; and
- are any deductions missing the classification and payee data needed for reconciliation.

This PR deliberately does **not** claim that a liability has been paid. Payment records, allocations, confirmation numbers, evidence, due-date schedules, and settlement statuses belong in the next bounded payment-ledger PR.

## Scope

### Included

1. Effective-dated, company-scoped pay-component classification rules with source, version, approval, and filing/report mappings.
2. A versioned application-default rule snapshot when no database override exists.
3. Immutable payroll-liability posting headers and detail entries.
4. Automatic posting inside the existing payroll-commit transaction.
5. Automatic posting for committed per-employee corrective supplemental payroll.
6. Reversing journal postings when a committed pay period is voided.
7. Reversal and replacement postings when a committed pay date is corrected.
8. Idempotency and row-locking for commit, reversal, correction, and backfill paths.
9. A company-scoped read-only reconciliation endpoint and pay-period UI.
10. Explicit warnings for legacy custom deductions and ad-hoc adjustments that lack a liability category/payee.
11. An operator-controlled historical backfill with preview-first and explicit confirmation.
12. Consistent inclusion of W-4 Step 4(c) extra withholding in Guam withholding deposit and annual/quarterly reconciliation totals.

### Explicitly excluded

- recording tax or third-party payments;
- allocating one payment across liabilities;
- deposit schedules and legal due-date calculation;
- authority confirmation numbers and receipt evidence;
- direct deposit/NACHA;
- PTO, garnishment-case administration, benefit-plan administration, and general ledger journal exports;
- changing existing wage, tax, deduction, employer-tax, or net-pay calculations; and
- automatically rewriting or backfilling historical payroll during migration.

## Data model

### `pay_component_tax_rules`

Stores company-specific effective-dated overrides. Rules include:

- component key and kind;
- FIT/Guam withholding, Social Security, Medicare, and Additional Medicare treatment;
- W-2GU, Form 941, SWICA, retirement, and reimbursement classifications;
- register presentation and optional GL account;
- effective dates, source, version, approver, and approval time.

An active company rule may not overlap another active company rule for the same component. Global/application defaults remain available when no override exists. Once a rule is referenced by a committed liability entry, it cannot be edited; a later correction requires a new effective-dated version.

### `payroll_liability_postings`

An immutable journal header. Posting types are:

- `commit` — created with a newly committed payroll;
- `historical_backfill` — explicitly captures a pre-ledger committed payroll;
- `replacement` — re-establishes a liability on a corrected pay date; and
- `reversal` — exactly negates one earlier source posting.

Every posting stores the company, pay period, liability date, operator, timestamp, idempotency key, reason, metadata, and complete component-rule snapshot.

### `payroll_liability_entries`

Immutable detail rows tied to stored payroll-item amounts. Initial categories include:

- Guam income tax withholding, including separately stored W-4 Step 4(c) withholding;
- employee and employer Social Security;
- employee and employer Medicare;
- employee Additional Medicare;
- employee and employer retirement/Roth amounts;
- employee insurance deductions;
- classified garnishment, child-support, and benefit fields; and
- other explicitly classified payroll liabilities.

No liability service calls a payroll calculator. The posting amount comes only from the committed `payroll_items` and their snapshotted component entries.

## Lifecycle behavior

### Normal commit

```text
approved payroll
  -> existing commit transaction begins
  -> payroll status and YTDs update
  -> immutable liability posting is created from stored payroll items
  -> checks and configured downstream work continue
  -> transaction commits
```

If liability posting fails, the payroll status, YTD updates, check assignment, and posting all roll back together.

### Void

```text
committed payroll + open liability posting
  -> existing correction lock and validation
  -> YTD reversal
  -> immutable negative reversal posting
  -> pay period marked voided
  -> transaction commits
```

The original posting is never updated or deleted.

### Pay-date correction

```text
old-date posting
  -> negative reversal on old liability date
  -> equal replacement on corrected liability date
```

This preserves quarter/month history without changing paycheck amounts.

### Historical payroll

The migration creates empty additive tables only. It does not recalculate, modify, or silently backfill prior pay periods.

The reconciliation endpoint reports an existing committed period with no postings as `legacy_unposted`. Operators can preview an explicit backfill:

```bash
cd api
COMPANY_ID=123 THROUGH_DATE=2026-06-30 bin/rails payroll_liabilities:backfill
```

After validating the listed pay-period IDs, database backup, and comparison totals:

```bash
cd api
COMPANY_ID=123 THROUGH_DATE=2026-06-30 CONFIRM=BACKFILL bin/rails payroll_liabilities:backfill
```

The backfill reads stored committed values only. It does not invoke payroll calculation and is idempotent.

## API and UI

### Liability reconciliation

`GET /api/v1/admin/pay_periods/:pay_period_id/payroll_liabilities`

Returns:

- status: `not_applicable`, `legacy_unposted`, `posted`, `attention_required`, or `reversed`;
- net recorded liability;
- totals by category and recipient;
- immutable journal history and entries;
- unclassified legacy deductions/adjustments; and
- an explicit indication that payment tracking is not part of this phase.

The Pay Period page shows the same information without representing recorded obligations as paid.

### Component rules

- `GET /api/v1/admin/pay_component_tax_rules`
- `POST /api/v1/admin/pay_component_tax_rules`
- `PATCH /api/v1/admin/pay_component_tax_rules/:id`

Staff may read rules. Manager/admin authority is required to create or revise unused rules. Used rules are immutable.

## Backward-compatibility guarantees

1. The migration is additive.
2. Existing payroll rows and financial columns are not backfilled or changed.
3. No payroll calculation formula uses the new ledger tables.
4. New postings copy stored committed amounts rather than reconstructing them from gross pay.
5. Existing reports continue to query committed payroll items; the ledger is a new reconciliation record.
6. Voiding a legacy committed period first captures its stored amounts and then creates an equal reversal.
7. Backfill requires an explicit operator command and confirmation.
8. Every mutating path is company-scoped, locked, transactional, and idempotent.

## W-4 Step 4(c) reconciliation correction

The audit found that Step 4(c) extra withholding was deducted from employee net pay but omitted from several deposit and filing totals that summed only `withholding_tax`. Official W-2 instructions require Box 2 to show total Guam income tax withheld for W-2GU, and the Step 4(c) amount is additional tax withheld each pay period.

This PR does not change how withholding is calculated. It consistently totals the two stored components for:

- automatic Guam FIT deposit checks;
- Form 500 defaults;
- W-2GU Box 2;
- Guam W-1/quarterly reconciliation context;
- tax-sync aggregate totals; and
- the payroll-liability ledger and pay-period obligation display.

The separate columns remain visible for audit purposes.

## Required validation

Before merge:

1. Apply the migration from the current production schema.
2. Roll the migration back and reapply it against an isolated database.
3. Run model, service, request, correction, Form 500, Form 941, W-2GU, tax-sync, and quarterly packet tests.
4. Run the full backend suite, RuboCop, Brakeman, and dependency audit.
5. Run frontend typecheck, lint, production build, and Playwright smoke tests.
6. Compare representative existing payroll calculations before and after the branch; gross, tax components, deductions, employer taxes, and net pay must be unchanged.
7. Commit a new representative payroll and confirm its liability categories equal stored payroll-item amounts.
8. Void a disposable committed payroll and verify the ledger nets to zero without deleting the original posting.
9. Correct a disposable pay date across a month/quarter boundary and verify old-date net zero plus equal new-date replacement.
10. Preview historical backfill only; do not execute against production until backup and rollout approval are complete.

## Deployment sequence

1. Take and verify a production database backup.
2. Deploy the additive migration and application code.
3. Commit a controlled payroll and inspect the new ledger.
4. Validate Form 500, W-1 context, W-2GU Box 2, Form 941 context, checks, and payroll reports.
5. Run a historical backfill preview per company.
6. Reconcile preview totals to authoritative payroll reports.
7. Execute backfill company-by-company only after approval.
8. Begin the next bounded PR for payment records, allocations, confirmations, evidence, and due-date schedules.
