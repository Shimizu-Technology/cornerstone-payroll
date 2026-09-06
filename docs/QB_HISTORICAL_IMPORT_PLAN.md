# QuickBooks Historical Import Plan

**Status:** core importer, protected source retention, and unified historical reporting are implemented and locally validated; cutover evidence remains before a production import
**Owner:** Leon / Shimizu Technology  
**Last reviewed:** 2026-09-06

## Decision and implementation record

QuickBooks history now has a separate, immutable archive instead of using the live `PayPeriod` and `PayrollItem` calculation path. This is the central safety decision.

The historical import lane now:

- requires one authoritative Payroll Details, Paycheck History, Payroll Summary, Employee Details, and Employee Directory report, plus optional supporting XLS, XLSX, PDF, JPEG, and PNG files;
- inventories every supplied file with its filename, size, report classification, and SHA-256 digest;
- retains every original export in private application-managed object storage and verifies the downloaded bytes against the recorded size and SHA-256 digest;
- preserves QuickBooks' final paycheck values and itemized breakdowns without running Cornerstone's payroll calculators;
- encrypts the private Employee Details snapshot at rest;
- stages the bundle as a preview, requires an explicit acknowledgement before apply, and locks a reconciled import against later edits;
- requires an attributed manager or administrator with access to the company for every apply, lock, and manual worker mapping, including command-line operations;
- detects an identical bundle and reuses the prior batch instead of importing it twice;
- blocks missing or duplicate required reports, mixed-company bundles, unmatched native paychecks, ambiguous duplicate paycheck signatures, altered staged totals, and overlap with already-applied history;
- lets accountants browse the archive while limiting preview, apply, lock, and employee mapping to managers and administrators;
- never creates or changes live pay periods, payroll items, YTD aggregates, payments, tax filings, checks, reminders, or notifications.

The archive uses five dedicated records:

- `HistoricalImportBatch` records provenance, validation, reconciliation, lifecycle state, and operator attribution.
- `HistoricalImportSourceFile` records immutable source metadata, private object location, verification state, and the user who uploaded it.
- `HistoricalWorker` preserves the QuickBooks worker identity and an optional link to a current employee.
- `HistoricalPayPeriod` groups source paychecks by period and pay date.
- `HistoricalPaycheck` stores the authoritative money, hours, taxes, deductions, contributions, payment metadata, and source-row evidence.

This is intentionally an archive and reconciliation feature. It does not recreate old payroll as editable live payroll and does not backfill current YTD balances.

## Historical report boundary

Accepted `applied` and `locked` batches feed five read-only report views:

- payroll register;
- employee summary;
- employee and employer tax detail;
- pre-tax deductions, after-tax deductions, loans, retirement items, and employer contributions;
- check and payment history.

Each view supports all-years or source-pay-year filtering, an optional worker filter, pagination, and CSV, XLSX, and PDF exports. The report response and Excel workbook include source-batch provenance and verified-file counts. Accountants can use these views; previews remain excluded from official history.

Opening summaries are always counted and totaled separately from detailed paychecks. They may cover a span of dates for which QuickBooks did not supply individual paycheck periods, so the system does not represent them as monthly or quarterly activity. Reports use QuickBooks' stored values without invoking Cornerstone calculators, writing live YTD totals, or exposing employee SSNs, encrypted snapshots, or private object-store keys.

## Verified MoSa bundle

The read-only QuickBooks export collected on 2026-09-05 contains 45 files. The parser currently produces:

- 113 historical workers, including workers with no paycheck in the exported range;
- 59 historical period groups;
- 2,881 paycheck snapshots from 2024-06-30 through 2026-08-27;
- 2,833 native paycheck rows that match Payroll Details to Paycheck History exactly;
- 48 opening-balance rows covering 2023-12-29 through 2024-06-27;
- 255 preserved check numbers.

Verified bundle totals:

| Measure | QuickBooks total |
| --- | ---: |
| Gross pay | $4,766,581.41 |
| Adjusted gross | $4,566,330.54 |
| Pretax deductions | $200,250.87 |
| Employee taxes | $765,110.85 |
| Federal income tax | $421,788.51 |
| Social Security | $273,424.34 |
| Medicare | $69,898.00 |
| After-tax deductions | $409,028.99 |
| Net pay | $3,392,190.70 |
| Employer taxes | $341,671.91 |
| Employer contributions | $108,013.60 |
| Total payroll cost | $5,216,266.92 |

The native Payroll Details and Paycheck History exports reconcile exactly at 2,833 rows, $3,970,837.34 gross, and $2,822,901.55 net. The 48 early records are only opening summaries because QuickBooks did not provide their original paycheck-level periods in these reports. The UI and API label them accordingly instead of pretending they are complete individual pay periods.

The totals above include two QuickBooks void/reversal rows. Employee taxes and deductions use a payroll-facing sign convention: normal withholding is positive and reversal withholding is negative. Employer taxes, employer contributions, gross, net, and total payroll cost retain their QuickBooks report direction. This makes the stored aggregates agree with the signed source report instead of inflating totals by taking absolute values.

QuickBooks Paycheck History omits a check number on 2,578 of the 2,833 native paychecks; the 48 opening-balance rows also carry no check number. The archive preserves the 255 numbers that exist and reports the missing values as source-data warnings, not import failures.

## Source-retention boundary

The database stores the structured payroll history, encrypted employee snapshot data, and an immutable cryptographic inventory of every supplied file. Original XLS, XLSX, PDF, and image bytes are stored outside the database in the application's private object store.

Every file is downloaded and checked against its recorded byte size and SHA-256 digest immediately after upload, again before apply, again before lock, and before an authorized download. Apply and lock are blocked if the inventory is incomplete or any file is unavailable or altered. Managers and administrators can verify and download originals; accountants can review filenames, classifications, fingerprints, and status but cannot download reports that may contain SSNs. Private storage keys are never returned by the API.

Application retention does not remove the need for an approved records-retention period, restricted object-store credentials, provider-side durability/backups, and a tested restore procedure. QuickBooks access must remain available until those operational controls and the final cutover evidence are approved.

## Local operator runbook

The task defaults to preview-only. `APPLY=1` is required to make the archive visible, and `LOCK=1` also requires `APPLY=1`. Every run requires `ACTOR_EMAIL`; that user must be a manager or administrator with access to the company.

```sh
DATABASE_URL=postgres://localhost:5432/cornerstone_payroll_qbo_history_local \
BUNDLE_DIR=/absolute/path/to/quickbooks-export \
COMPANY_ID=<local-company-id> \
ACTOR_EMAIL=<local-operator-email> \
bundle exec rails quickbooks_history:import
```

After reviewing the preview and reconciliation:

```sh
DATABASE_URL=postgres://localhost:5432/cornerstone_payroll_qbo_history_local \
BUNDLE_DIR=/absolute/path/to/quickbooks-export \
COMPANY_ID=<local-company-id> \
ACTOR_EMAIL=<local-operator-email> \
APPLY=1 LOCK=1 \
bundle exec rails quickbooks_history:import
```

The command prints the import outcome, batch and company IDs, aggregate counts, state, warning and error counts, and a shortened digest. It does not print employee names, tax identifiers, addresses, or banking data.

## Promotion gate

Before any production import:

1. Run all backend, frontend, security, migration, and browser checks against an isolated database.
2. Confirm the MoSa local archive counts and totals above from both the database and the UI.
3. Have Cornerstone review the opening-summary and missing-check-number warnings.
4. Confirm application source retention is complete, every fingerprint verifies, and the private object store has an approved retention policy, backup/durability control, and tested restore path.
5. Deploy the feature through the normal reviewed pull-request and deployment process.
6. Create a production preview only. Review its reconciliation before applying it.
7. Apply and lock only after written approval from the responsible Cornerstone operator.

No production preview, apply, or lock has been performed as part of the local implementation.

## Production completion sequence

The QuickBooks exit is deliberately split into four reviewable releases. Finishing the first release does not authorize a production import.

1. **Importer safety and reconciliation:** strict five-report contract, exact name-and-SSN auto-linking, explicit manual/archive-only review, feature gating, immutable lifecycle, and live-payroll isolation.
2. **Protected source retention (implemented; production verification pending):** application-managed private source-file storage, access controls, hashes, retention status, and integrity-checked downloads so the original evidence is not lost when QuickBooks access ends. Provider durability/backup and restore evidence remain operational cutover gates.
3. **Unified read-only history and reports (implemented; production verification pending):** payroll register, employee summary, tax, deduction/contribution, retirement, loan, and check views read only accepted historical snapshots without writing to live YTD or recalculating historical values. UI and exports label their QuickBooks source, provenance, and opening-summary limitations.
4. **Cutover evidence and signoff:** repeatable reconciliation artifacts, exception disposition, independent aggregate checks, operator approval, rollback rehearsal, and a final no-QuickBooks dependency checklist.

The production feature flag remains off until these releases are deployed and the cutover gate is signed. The first production action is a preview; apply and lock require separate operator approval.

## Purpose

Cornerstone wants to fully leave QuickBooks and move historical company data into Cornerstone Payroll. The working assumption now is:

- import data for **all clients**
- import roughly the last **3-4 years**
- import **all payroll history**
- import other QuickBooks-backed payroll-supporting data wherever QuickBooks is currently acting as the archive of record

This document defines what the current system can and cannot do, what QuickBooks data we still need to inspect, and what must be built so historical QuickBooks data can be imported safely without mutating or reinterpreting prior payroll history.

The sections below retain the discovery rationale that led to the implemented design. Where an older recommendation conflicts with the decision record above, the decision record is authoritative.

## Current State

### What existed before this implementation

- Payroll can be created and processed natively through `PayPeriod` + `PayrollItem`.
- Historical-style backfill has been done for MoSa, but only through the existing live-payroll model.
- The current import UI is scoped to:
  - Revel payroll PDF
  - optional tips/loans Excel
  - one pay period at a time
  - existing editable pay periods only
- Imported rows currently call the live payroll calculators and then roll into live YTD totals at commit time.

### What that means

The current import flow is suitable for:

- operational imports for active payroll
- supervised one-period-at-a-time backfills
- MoSa-specific source files

It is **not** yet suitable for:

- bulk QuickBooks historical migration
- preserving historical payroll exactly as QuickBooks recorded it
- importing inactive/terminated employees reliably
- importing arbitrary QuickBooks exports with unknown schemas
- creating a durable migration audit trail across many periods/companies

## Key Constraint In The Current Architecture

Today, imported payroll is still treated as payroll to be **calculated by Cornerstone**, not as an authoritative historical ledger.

Current behavior:

- import matches against active employees already in the app
- imported data is written onto `PayrollItem`
- `PayrollItem#calculate!` recomputes withholding, FICA, net pay, deductions, and YTD-on-item values using current calculator logic
- committing the period mutates `EmployeeYtdTotal` and `CompanyYtdTotal`

That is correct for live operations, but dangerous for QuickBooks history because:

- historical employee setup may no longer match current employee setup
- tax tables may differ from the year the payroll originally ran
- prior manual adjustments in QuickBooks may not be reproducible from raw hours/rates alone
- historical check numbers, deductions, and tax outputs must be preserved as recorded

## Product Goal

Support a **historical import lane** that can ingest exported QuickBooks history across all payroll clients and represent it in Cornerstone Payroll without reinterpreting prior records.

Primary outcome:

- Cornerstone can browse/search/report on prior pay periods and related historical payroll data inside our app after leaving QuickBooks.

Secondary outcome:

- imported history should support tax reports, employee history, check history, and audit review without operators needing QuickBooks as the archive of record.

### In Scope For Discovery

At minimum, discovery and import design should cover:

- companies / clients
- employees and historical staff relationships
- pay periods
- employee paycheck-level payroll records
- employer tax totals tied to payroll
- deductions, contributions, loans, and benefits that affect payroll history
- check numbers / payment history where QuickBooks is the retained source
- year-to-date and quarter-to-date reporting support data if not safely derivable

Open question:

- whether Cornerstone also needs non-payroll accounting data from QuickBooks, or only payroll-domain data plus enough supporting metadata to replace QuickBooks for payroll operations and audit lookup

## Discovery work completed for MoSa

The MoSa package supplied the required reports and enough supporting quarterly, annual, tax, deduction, retirement, directory, time-off, check, PDF, and image evidence to design and validate the first importer. New clients must still be previewed because report shape and data quality can differ by company and QuickBooks usage.

### Files we need from Cornerstone

For one representative client, collect:

- payroll summary export for several periods
- payroll detail / payroll item export
- employee list export
- check register export
- deduction / contribution detail export
- tax liability / tax payment export
- quarterly filing support exports if available
- year-end export if available
- any company setup or employee tax setup export QuickBooks provides

For the broader build, we will need the same sample set from more than one client because export shape and data quality may differ by client and QuickBooks usage pattern.

### Questions to answer from sample files

1. What export formats are actually available?
   - CSV
   - XLSX
   - IIF
   - PDF only
   - zipped report bundle
2. Does QuickBooks expose stable identifiers for:
   - employee
   - pay period / paycheck
   - company
   - check
   - tax payment
3. Are pay periods explicit, or do we need to infer them from check/pay dates?
4. Are taxes stored as final outputs only, or as reconstructable inputs?
5. Are deductions and employer contributions broken out cleanly?
6. Are voids, corrections, reissues, and off-cycle payrolls visible in export data?
7. Do reports contain enough information to reconstruct:
   - gross
   - net
   - withholding
   - employee SS/Medicare
   - employer SS/Medicare
   - tips
   - loans
   - retirement
   - custom deductions
   - employer contributions
   - check/payment status
8. How are terminated employees represented?
9. How are historical pay-rate changes represented?
10. Do historical YTD totals need to be imported directly, or can they be derived safely from imported paychecks?
11. Which non-payroll QuickBooks records, if any, are still required for payroll audit/support workflows after migration?

## Recommended Import Strategy

### 1. Separate live payroll import from historical import

Do **not** force QuickBooks history through the existing MoSa/Revel import modal.

Instead, create a dedicated historical-import workflow with:

- batch upload
- dry-run validation
- mapping review
- import execution
- post-import reconciliation report

### 2. Treat imported history as authoritative snapshots

For QuickBooks historical data, the system should prefer imported final values over recalculation.

That means the import must support storing final historical values such as:

- hours
- gross pay
- net pay
- withholding tax
- SS tax
- Medicare tax
- employer SS
- employer Medicare
- tips
- loan deductions
- retirement deductions
- check number
- pay date
- status/void metadata

If a historical period is imported, Cornerstone should not silently recompute those values from today’s employee record.

### 3. Preserve external traceability

Every imported entity should retain external source references where available:

- source system: `quickbooks`
- source company id / name
- source employee id
- source paycheck id
- source pay period id
- source check number
- source file name / batch id

### 4. Build for reconciliation, not blind import

The import workflow should produce reconciliation output at both:

- period level
- employee/check level

Minimum validation:

- employee count
- gross total
- net total
- withholding total
- SS total
- Medicare total
- employer tax totals
- deduction totals
- check count
- check number collisions
- unmatched employees
- duplicate source records

## Data Model Requirements

These are the capabilities the data model needs, whether achieved by extending existing tables or adding new ones.

### Required capabilities

- historical import batch tracking
- immutable source metadata per imported record
- support for imported payroll rows that do not require recalculation
- support for inactive/terminated employees tied to historical payroll
- import audit trail with preview/apply/failure states
- idempotent re-run behavior for the same source file/batch
- duplicate detection

### Strongly recommended additions

- `historical_import_batches` or equivalent
- source identifiers on pay periods and payroll items
- a flag or mode indicating a payroll item/pay period is an authoritative imported snapshot
- structured reconciliation results persisted per batch
- mapping table for external employee identifiers to internal employees

### Risk with using only the current tables

The current schema can store many payroll values, but without an import-snapshot lane we risk:

- recomputation drift
- unclear provenance
- difficult re-import behavior
- hard-to-debug YTD mismatches

## Employee Mapping Requirements

Employee matching cannot rely only on fuzzy names for QuickBooks history.

We need a mapping strategy that can handle:

- active employees
- terminated employees
- renamed employees
- duplicate names
- middle initials / suffixes
- contractors vs employees

Recommended matching priority:

1. external employee id
2. SSN or masked tax identifier if safely available
3. normalized full name + DOB
4. normalized full name + hire date / email
5. manual mapping review

Historical import must also allow creating archived employee records when the person does not exist in the current active roster.

## Pay Period Requirements

Historical QuickBooks import needs more than “upload into an editable period.”

Needed behavior:

- create pay periods in bulk
- mark imported historical periods clearly in UI
- lock them against ordinary live-payroll editing by default
- preserve original pay date, start date, end date, and cycle type
- support supplemental/off-cycle/correction periods when present

Open design question:

- Should imported historical periods live in the main `PayPeriod` table with a historical/snapshot mode, or in a parallel archive model surfaced through the same UI?

Recommendation:

- Prefer reusing `PayPeriod` if we can guarantee imported periods are clearly marked, protected from recalculation, and compatible with reporting.
- If that becomes too invasive, use an archive model and add a unified read layer.

## Reporting Requirements

Imported QuickBooks history is only useful if the rest of the app can read it correctly.

Reports that must be validated against imported history:

- payroll register
- employee pay history
- YTD summary
- tax summary
- 941-GU support data
- W-2GU support data
- check register / print history

Important question:

- Should imported history contribute to our existing YTD aggregate tables directly, or should those aggregates be rebuildable from imported records in a controlled backfill/rebuild step?

Recommendation:

- Do not increment live aggregates blindly during import.
- Prefer a controlled aggregate rebuild for imported historical ranges, or an import mode that writes authoritative YTD values with reconciliation.

## Suggested Implementation Phases

### Phase 0 — Sample Intake

- collect real QuickBooks sample exports
- collect samples from multiple clients, not just one
- catalog each file type and field set
- choose MVP import package
- define exact source-to-target mapping

### Phase 1 — Import Contract + Schema

- define canonical import payload
- add source metadata fields/tables
- add import batch / reconciliation tables
- decide snapshot vs recalculated mode

### Phase 2 — Employee/Company Mapping

- build employee mapping flow
- support archived historical employees
- support duplicate and unresolved mapping review

### Phase 3 — Historical Period Import

- create periods in bulk
- import payroll rows as authoritative history
- run validation + reconciliation
- lock imported periods

### Phase 4 — Reporting Validation

- verify employee history, YTD, and tax reports against imported QuickBooks data
- add targeted fixes for any report assumptions that only work for live-calculated periods

## MVP Recommendation

For the first deliverable later this week, do **not** try to support every possible QuickBooks export or every client at once.

MVP should be:

- one client
- one known QuickBooks export bundle
- one import lane for historical pay periods
- authoritative historical snapshot import
- reconciliation report

That is enough to validate architecture before broadening to all client/company export variants.

After MVP validates the approach, the production target expands to:

- all active Cornerstone payroll clients
- roughly 3-4 historical years
- payroll-domain QuickBooks history, not just pay-period rows

## Immediate Next Steps

1. Ask Cornerstone for a representative QuickBooks export package.
2. Save those sample files outside git because they will likely contain PII.
3. Create a field inventory spreadsheet:
   - source file
   - source column
   - meaning
   - target field/table
   - required vs optional
   - import behavior
4. Decide whether imported historical periods will:
   - live inside `PayPeriod` with snapshot semantics, or
   - live in a separate archive model.
5. Only after those decisions, start implementation.

## Current Recommendation

When we build this, we should assume:

- the existing MoSa import pieces are reusable only in limited ways
- QuickBooks history needs a dedicated import architecture
- correctness and provenance matter more than speed of first implementation

If we do not treat historical QuickBooks payroll as authoritative imported history, we risk producing data that looks imported but is actually a recomputed approximation.
