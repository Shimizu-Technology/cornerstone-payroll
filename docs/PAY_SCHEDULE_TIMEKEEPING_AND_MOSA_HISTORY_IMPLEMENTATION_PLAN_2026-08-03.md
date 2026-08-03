# Pay Schedule, Timekeeping, and MoSa History Implementation Plan

**Plan date:** August 3, 2026
**Status:** In progress; PR 1 schedule and pay-run foundation implemented on the feature branch
**Design source:** [Pay Schedules, Salary Timekeeping, and Client Cloning](PAY_SCHEDULE_SALARY_TIMEKEEPING_AND_CLIENT_CLONE_DESIGN_2026-08-03.md)
**Historical source:** [QuickBooks Historical Import Plan](QB_HISTORICAL_IMPORT_PLAN.md)

## Outcome

Deliver a payroll foundation that:

- stores effective-dated pay schedules and legal workweeks;
- records salary employees' scheduled and actual time without changing ordinary salary math;
- supports exempt and nonexempt salary treatment;
- distinguishes regular payroll from tips-only, bonus, correction, final, and adjustment runs;
- backfills Krystel Perez's confirmed AIRE schedule without duplicating correction-period time;
- allows Cornerstone to start a clean payroll ledger for an existing client while retaining its setup; and
- reconstructs MoSa's current and prior payroll years one authoritative pay period at a time.

The work is intentionally split into bounded PRs. Schema deployment, application activation, historical backfill, and production cutover are separate actions.

## Guiding rules

1. Existing payroll money does not change merely because schedules or time records are added.
2. Salary pay basis, W-2/1099 classification, and overtime exemption are independent concepts.
3. Pay periods do not define the legal overtime workweek.
4. Historical QuickBooks values are snapshots, not inputs for current calculators.
5. Test and parallel payroll never enter authoritative YTD or filing totals.
6. Historical operations are dry-run first, idempotent, reconciled, and audited.
7. Raw payroll files and PII remain outside git and out of logs.

## PR 1 — Pay-run purpose and schedule foundation

### Schema

Add effective-dated company configuration for:

- payroll frequency;
- period-boundary rule;
- pay-date rule or manual-date mode;
- legal workweek starting weekday/time;
- timezone;
- source and confidence;
- confirmation state, confirmer, and effective dates.

Add payroll-run fields for:

- purpose (`regular`, `off_cycle_tips`, `bonus`, `commission`, `correction`, `final`, or `adjustment`);
- `includes_base_salary`; and
- source/audit metadata.

### Migration

- AIRE: semimonthly 1st–15th and 16th–month-end; future pay date remains manual pending review.
- Spike: biweekly Sunday–Saturday and ordinary Friday pay date.
- MoSa test ledger: recent Monday–Sunday and Thursday pay-date pattern, marked production-inferred.
- Cornerstone Internal and Shimizu Technology: retain biweekly frequency in manual-date mode.
- Preserve Sunday as the current legacy overtime-workweek default, visibly unconfirmed where the employer has not supplied its legal workweek.
- Label Spike pay period #43 as `off_cycle_tips` through an idempotent data migration or controlled service; do not recalculate it.

### Product behavior

- Non-regular runs default to no base salary.
- Operators see the source and confirmation status of an inferred schedule.
- Existing manually entered dates continue working.
- Commit warns when a legal workweek is still a legacy default; it does not silently claim employer confirmation.

### Release gate

- No salary, hourly, tax, tips, or net-pay regression across existing calculator tests.
- An off-cycle tips run cannot generate salary or scheduled work time.

### PR 1 implementation record

- `company_pay_schedules` stores effective-dated frequency, period boundaries, pay-date handling, source, and confirmation evidence. Automatic biweekly rules also require a known period-start anchor so the correct alternating-week parity is never guessed from a weekday alone.
- `company_workweeks` stores the separate effective-dated legal overtime workweek and preserves the prior Sunday assumption as visibly unconfirmed.
- `pay_periods.run_purpose` and `pay_periods.includes_base_salary` snapshot the operator's intent for each run without overloading correction lifecycle state.
- Salary calculation enforces zero base salary for an off-cycle tips run even if a stale salary override exists.
- New and edited payroll runs display purpose, salary treatment, schedule-derived date guidance, and an employer-confirmation warning before commit.
- The Pay Schedule & Workweek settings page exposes inferred/legacy provenance, records a required confirmation note, and creates new effective-dated records instead of rewriting history.
- If a legacy biweekly configuration has no trustworthy anchor, new payroll dates stay blank and manual until an operator confirms one; the UI never silently substitutes a weekly cycle.
- Production backfill is idempotent, links existing pay periods to the seeded schedule/workweek, labels correction flows without changing their money, and relabels Spike pay period `#43` as tips-only without recalculation.

## PR 2 — Employee schedule and overtime profile

### Schema

Add effective-dated employee configuration for:

- pay basis;
- overtime status (`exempt`, `nonexempt`, or `needs_review`);
- exemption category/reason;
- standard weekly hours;
- daily schedule;
- timekeeping mode (`imported`, `manual`, or `schedule_with_exceptions`); and
- source, confirmation, and audit metadata.

Do not merge these fields back into W-2/1099 classification.

### UI

- Show plain-language explanations for pay basis versus overtime status.
- Require a reason/effective date when status changes.
- Show the configured daily schedule and weekly total.
- Default a confirmed conventional schedule to Monday–Friday, 8 hours daily only when explicitly selected or migrated for a named employee.
- Do not default all salary employees globally to 40 hours.

### Release gate

- Effective-dated changes do not rewrite prior payroll snapshots.
- Permissions and audit coverage match other sensitive employee changes.

## PR 3 — Payroll ledger/workspace separation and clean setup clone

### Recommended architecture

Keep one `Company` as the legal employer and introduce payroll ledgers/workspaces beneath it. This avoids duplicate EINs and avoids duplicating sensitive employee records merely to start with no pay periods.

Each ledger has:

- mode (`test`, `parallel`, `live`, or `archived`);
- predecessor/source ledger;
- effective dates;
- authoritative status;
- creation reason and actor; and
- an immutable clone/start audit event.

Pay periods and payroll-derived transactional records are scoped to a ledger. Employee and company setup remain shared unless a future requirement calls for an effective-dated copy.

### Clone client setup / Start clean payroll ledger

The action:

1. previews what remains shared and what starts empty;
2. creates a new non-authoritative ledger;
3. carries schedule/import/check-layout configuration intentionally;
4. creates no pay periods, payroll items, checks, filings, liabilities, or YTD rows;
5. never exposes SSNs or bank data in preview/logs; and
6. requires super-admin authorization and a reason.

### Reporting isolation

- Every payroll, filing, YTD, liability, check, reminder, and report query must specify the intended ledger authority.
- Test/parallel ledgers appear in comparison views but not official totals.
- Exactly one live authoritative ledger is permitted per company.

### Release gate

- A cross-ledger query audit proves no official report leaks test payroll.
- Company EIN remains unique and unchanged.
- Existing companies receive a default ledger without changing their results.

## PR 4 — Daily time ledger and payroll allocation

### Data model

Create a daily time record capable of storing:

- employee and work date;
- workweek key;
- scheduled hours;
- actual worked hours;
- PTO and holiday hours;
- overtime allocation;
- import/schedule/manual source;
- exception and override reason; and
- revision/audit provenance.

Create an allocation/link from payroll items or pay periods to the daily records represented by that run. Correction and replacement payrolls must reference the original work dates instead of creating duplicate daily records. The allocation must identify the payroll ledger so parallel and live runs can use the intended time evidence without leaking results across ledgers.

### Calculation behavior

- Schedule-with-exceptions supplies the confirmed daily schedule unless a deviation exists.
- Imported time takes precedence over the schedule for the affected dates.
- Exempt salary time is informational/compliance data and does not multiply base salary.
- Nonexempt salary overtime is calculated by the configured seven-day workweek.
- Semimonthly periods may contain partial workweeks; the calculator fetches the complete boundary workweeks before allocating period overtime.

### UI

- Replace disabled zero-hour salary inputs with scheduled/actual time visibility.
- Permit authorized exception entry without changing ordinary salary unintentionally.
- Prevent the payroll screen from zeroing imported salary hours.

### Release gate

- Imports survive reopen/rerun.
- Workweek changes are effective-dated.
- No time duplication across void/correction/replacement flows.
- Parallel/test time allocations cannot enter authoritative payroll results.

## PR 5 — AIRE backfill and production schedule activation

### Krystel

- Create Monday–Friday, 8-hour schedule-with-exceptions records.
- Proposed effective date: March 1, 2026, based on the first payroll period currently present; record that the production hire date was blank.
- Dry-run daily/workweek/period totals.
- Exclude the voided original March period and link the replacement to the same work dates.
- Do not change salary gross, taxes, or net.
- Write an audit event with actor, source, dates, totals, and assumptions.

### Production schedule activation

- Confirm AIRE's legal workweek and overtime status before treating migrated defaults as employer-confirmed.
- Keep AIRE future pay dates manual until pay timing is reviewed.
- Activate Spike and MoSa inferred schedules only after their validation gates.

### Production execution

Deploying the code does not execute the backfill. Production execution requires:

1. dry-run output retained as evidence;
2. database backup/restore readiness;
3. exact target IDs and date range;
4. Leon approval;
5. Cornerstone operational approval; and
6. post-run report and audit verification.

## PR 6 — Authoritative historical-import framework

### Schema

Add:

- historical import batches with preview/apply/reconcile/lock states;
- source file hashes and source-system identifiers;
- external employee/paycheck/check mappings;
- authoritative snapshot mode on imported periods/items;
- structured reconciliation results; and
- idempotency constraints for each external record.

### Historical snapshot rules

- Store source-final gross, net, FIT/DRT, Social Security, Medicare, employer taxes, tips, deductions, contributions, check number, pay date, and status.
- Do not run the live calculator or current normalization callbacks over authoritative historical money.
- Preserve source employment classification, pay rate, tax treatment, and earning/deduction breakdown effective for that paycheck.
- Imported periods are locked against ordinary payroll editing.
- Corrections require a historical-import amendment/reconciliation workflow, not live recalculation.
- Historical records may feed reports but may not issue payments, print live checks, send tax syncs, post new deposits, or fire payroll reminders.

### Workflow

1. Upload/register source bundle.
2. Hash and inventory files.
3. Parse into a canonical staging format.
4. Resolve company, employee, period, and paycheck mappings.
5. Preview duplicates, gaps, and discrepancies.
6. Apply into a non-authoritative ledger.
7. Rebuild derived aggregates from imported snapshots.
8. Reconcile and lock the batch.
9. Promote only after signoff.

### Release gate

- Re-running the same batch is a no-op.
- Failed apply rolls back atomically.
- Imported reports equal fixture source totals.
- No live side effects occur.

## PR 7 — MoSa adapter and 2025 pilot year

### Reuse

Reuse the proven parts of the existing MoSa tooling:

- Revel PDF parser;
- tips/loan workbook parser;
- normalized name matching and aliases;
- 26-period 2025 coverage manifest; and
- period/employee reconciliation concepts.

Do not reuse its destructive apply behavior or its assumption that current Cornerstone calculations are the historical truth.

### Source hierarchy

1. QuickBooks final payroll/check/tax exports or equivalent finalized Cornerstone records are authoritative for money.
2. Revel is authoritative/supporting evidence for worked hours and rate detail when reconciled.
3. MoSa tip/loan workbooks enrich tip, loan, and adjustment detail but require comparison to final payroll handling.
4. Conflicts become explicit reconciliation exceptions; no adapter silently chooses a value.

### Pilot

- Import all 26 MoSa 2025 periods into the new non-authoritative ledger.
- Resolve the historical period-boundary inconsistencies in the existing script against the finalized payroll calendar.
- Include terminated/historical employees through external mappings.
- Preserve contractor/manual-check cases and off-cycle records.
- Compare every paycheck and each period to QuickBooks/final payroll.

### Required reconciliation

- employee/check count;
- regular, overtime, salary, tips, bonuses, and taxable additions;
- gross and net;
- employee and employer tax components;
- loans and other deductions;
- check/payment status;
- quarter totals; and
- annual W-2GU/941/SWICA support totals.

### Promotion gate

- Zero unexplained employee/check mismatches.
- Penny-level per-check tax/net reconciliation unless a documented source rounding rule explains the difference.
- Quarter and annual totals reconcile to authoritative reports.
- Cornerstone CEO/Ops and Leon sign off on the pilot evidence.

## PR 8 — Expand MoSa across all selected years

For each year, oldest to newest:

1. inventory all expected pay periods and source files;
2. identify missing regular and off-cycle runs;
3. import into staging;
4. reconcile per employee/check and period;
5. reconcile quarter and year totals;
6. lock the year; and
7. continue to the next year only after signoff.

The current year is imported through the final QuickBooks-authoritative period. Cornerstone-native live payroll begins with the first period after that cutoff. Because every earlier period is present, YTD is rebuilt from paychecks rather than seeded from opening balances.

If a historical period cannot be recovered, stop and document the gap. A controlled opening-balance snapshot may be considered only for the missing boundary, with explicit approval and report limitations.

## Cross-cutting test plan

### Backend

- model constraints and effective-date overlap;
- authorization and audit events;
- all salary frequency calculations;
- workweek boundary and semimonthly splitting;
- idempotent schedule and historical backfills;
- ledger isolation for every official aggregate;
- historical snapshot callback bypasses;
- void/correction/off-cycle behavior; and
- full rollback on batch failure.

### Frontend

- desktop and mobile schedule configuration;
- clear scheduled-versus-actual labels;
- exemption explanations and review warnings;
- run-purpose/base-salary guardrails;
- clone/start-ledger preview;
- historical import mapping and reconciliation; and
- visible test/parallel/live context.

### Reports

- payroll register;
- paycheck history;
- YTD/QTD summaries;
- W-2GU;
- Form 941;
- SWICA;
- 1099 where contractor history exists;
- check register; and
- liability/reconciliation views.

## Operational order

1. Merge and deploy each foundation PR with migrations only.
2. Verify existing production payroll remains unchanged.
3. Configure and dry-run in non-authoritative/test ledgers.
4. Complete the AIRE schedule backfill after its dedicated approval gate.
5. Complete MoSa 2025 pilot reconciliation.
6. Expand MoSa historical years.
7. Run at least two clean parallel cycles per client.
8. Promote the intended ledger to authoritative only after documented signoff.

## Definition of done

- Krystel has auditable schedule-based time with no salary recalculation.
- Spike's tips-only run cannot generate salary or work hours.
- MoSa has one company/EIN and isolated test/live payroll ledgers.
- Every selected MoSa historical pay period is imported and reconciled.
- YTD and filing reports derive from authoritative historical paychecks plus subsequent live payroll.
- No test/parallel data leaks into official reports.
- Pay schedules and workweeks are effective-dated, source-labeled, and reviewable.
- Greptile, automated tests, browser QA, migration dry runs, and operational signoffs are clean before production activation.
