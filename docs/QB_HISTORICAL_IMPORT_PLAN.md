# QuickBooks Historical Import Plan

**Status:** planned  
**Owner:** Leon / Shimizu Technology  
**Last reviewed:** 2026-04-23

## Purpose

Cornerstone wants to fully leave QuickBooks and move historical payroll data into Cornerstone Payroll. This document defines what the current system can and cannot do, what QuickBooks data we still need to inspect, and what must be built so historical QuickBooks payroll can be imported safely without mutating or reinterpreting prior payroll history.

This is intentionally a planning document, not an implementation spec for the existing MoSa import flow.

## Current State

### What exists today

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

Support a **historical import lane** that can ingest exported QuickBooks payroll history and represent it in Cornerstone Payroll without reinterpreting prior payroll.

Primary outcome:

- Cornerstone can browse/search/report on prior pay periods inside our app after leaving QuickBooks.

Secondary outcome:

- imported history should support tax reports, employee history, and audit review without operators needing QuickBooks as the archive of record.

## Discovery Work Still Required

We do **not** yet know the exact QuickBooks export package Cornerstone will hand us. That is the first blocker.

We need sample exports for at least one client and ideally one full quarter before implementation starts.

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
8. How are terminated employees represented?
9. How are historical pay-rate changes represented?
10. Do historical YTD totals need to be imported directly, or can they be derived safely from imported paychecks?

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

For the first deliverable later this week, do **not** try to support every possible QuickBooks export.

MVP should be:

- one client
- one known QuickBooks export bundle
- one import lane for historical pay periods
- authoritative historical snapshot import
- reconciliation report

That is enough to validate architecture before broadening to all client/company export variants.

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
