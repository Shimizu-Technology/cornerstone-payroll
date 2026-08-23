# Pay Schedules, Salary Timekeeping, and Client Cloning

**Decision date:** August 3, 2026
**Status:** Approved staged design; PR 1 is an unmerged draft foundation and PR 2 is implemented on a dependent feature branch pending local review
**Scope:** Cornerstone Payroll production clients, employee lifecycle history, salary-hour recordkeeping, pay-run purpose, and clean client cutover/cloning
**Related work:** PR #39 (zero-hour defaults), PR #105 (paid-out tip taxable gross), PR #121 (classification-history safeguards), and CPR-MP-016 in the payroll compliance master plan

## 1. Why this change exists

Cornerstone Payroll currently calculates ordinary salary pay independently of hours, which is correct for a complete salary pay period. It does not, however, retain salary employees' work hours consistently. The payroll worksheet forces salary hours to zero even when a time-tracking or payroll-intake import supplied hours.

This creates three separate problems:

1. Guam recordkeeping requires employers to retain hours worked each day and each workweek, including for employees paid on a salary basis.
2. `salary` is a pay basis, not an overtime exemption. A salaried employee may be exempt or nonexempt depending on the applicable salary and duties tests.
3. A generic default such as 40, 80, or 86.67 cannot safely represent actual hours for every employee or every pay period.

The change must also protect non-regular payrolls. Spike's historical tips-only payroll covers a six-week earning range. If salary hours or base pay were inferred only from the pay-period dates, a tips-only run could accidentally create salary pay or duplicate work hours.

Official references:

- [Guam Department of Labor FLSA Handbook, February 16, 2026](https://dol.guam.gov/wp-content/uploads/GDOL-FLSA-Handbook-as-of-2.16.2026.pdf)
- [U.S. DOL Fact Sheet #21 — FLSA recordkeeping](https://www.dol.gov/agencies/whd/fact-sheets/21-flsa-recordkeeping?lang=en)
- [U.S. DOL Fact Sheet #23 — overtime by workweek](https://www.dol.gov/agencies/whd/fact-sheets/23-flsa-overtime-pay)
- [U.S. DOL Fact Sheet #17G — salary basis and exemptions](https://www.dol.gov/agencies/whd/fact-sheets/17g-overtime-salary)
- [IRS Publication 15-T (2026) — payroll-period frequencies](https://www.irs.gov/publications/p15t)
- [IRS tip recordkeeping and reporting](https://www.irs.gov/businesses/small-businesses-self-employed/tip-recordkeeping-and-reporting)

## 2. Decisions agreed before implementation

### 2.1 Keep salary pay and timekeeping separate

For a normal complete salary pay period, base salary remains:

- annual salary divided by 52 for weekly payroll;
- annual salary divided by 26 for biweekly payroll;
- annual salary divided by 24 for semimonthly payroll;
- annual salary divided by 12 for monthly payroll; or
- the configured per-period/variable amount where applicable.

Hours recorded for an exempt salaried employee are compliance and operational records. They do not multiply or reduce ordinary base salary except through a separately reviewed partial-period, unpaid-leave, hire, termination, or correction workflow.

For a salaried nonexempt employee, actual work hours are required and overtime must be calculated separately for each fixed seven-day workweek. Hours cannot be averaged across a biweekly or semimonthly pay period.

### 2.2 Do not label schedule assumptions as unqualified actual time

The system will distinguish:

- **scheduled hours:** hours expected under the employee's confirmed schedule;
- **actual worked hours:** scheduled hours plus or minus recorded exceptions or imported time;
- **paid leave hours:** PTO or other paid leave, stored separately from worked hours;
- **holiday hours:** paid holiday time, stored separately from worked hours; and
- **overtime hours:** worked hours identified per legal workweek for a nonexempt employee.

A fixed schedule may use exception-based timekeeping: the schedule supplies the daily record unless the operator records a deviation. The source, confirmation, and any override reason must remain auditable.

### 2.3 Krystel Perez at AIRE

The current production salary employee is **Krystel Perez**. Her current record is a semimonthly, per-period salary record. Ten committed salary payroll items exist from March 1 through July 15, 2026, and currently store zero hours. One March pay period was voided and replaced by a correction period covering the same dates.

The agreed treatment is:

- a fixed remote schedule of Monday through Friday;
- 8 scheduled hours per workday;
- 40 scheduled hours per complete workweek;
- exception-based recording for PTO, holidays, unpaid time, or any confirmed schedule deviation; and
- salary pay remains independent of the scheduled-hour total for a normal complete period.

Remote work does not remove the need for time records. The migration/backfill will describe these as employer-confirmed schedule-based records. It will not attach a second set of hours to a correction run covering dates already recorded.

Krystel's production `hire_date` is currently blank. Unless AIRE supplies an earlier authoritative date, the proposed legacy schedule effective date is March 1, 2026, because that is the beginning of her first payroll period present in Cornerstone Payroll. The chosen date and its source must be written to the audit history.

### 2.4 Hourly employees with stipends remain hourly

AIRE's Chief Pilot and Assistant Chief Pilot compensation is correctly modeled as hourly wages plus a fixed taxable payroll addition. Production history includes:

- Chief Pilot: $750 taxable addition; and
- Assistant Chief Pilot: $250 taxable addition.

These additions increase taxable gross and related reporting. They do not represent extra work hours and do not turn the worker into a salaried employee.

### 2.5 Pay periods and legal workweeks are different records

The application will not infer the legal overtime workweek from the payroll-period boundary. A company may have a biweekly payroll period that contains two workweeks, but the workweek may begin on a different day. Semimonthly periods regularly split workweeks.

The system therefore needs separate effective-dated configuration for:

1. payroll frequency and period boundaries;
2. pay-date rule;
3. legal workweek starting day and time; and
4. employee work schedule.

### 2.6 Production-derived configuration should preserve current operation

The migration will use current production evidence so the rollout does not require operators to re-enter known schedules. Inference source and confidence must be retained. Ambiguous clients remain in manual-date mode instead of receiving an invented automatic schedule.

| Client | Production evidence as of August 3, 2026 | Proposed migration behavior |
|---|---|---|
| AIRE Services | Semimonthly periods: 1st–15th and 16th–month-end | Seed semimonthly period rule. Preserve existing dates. Keep future pay dates manual until the observed 14–16 day lag is reviewed against Guam pay-timing requirements. Seed Sunday as the legacy engine workweek default, marked as needing employer confirmation. |
| Spike Coffee Roasters | Biweekly periods consistently Sunday–Saturday; ordinary pay dates Friday | Seed biweekly Sunday–Saturday period rule and Friday pay-date rule. Workweek remains a separate field, initially sourced from the legacy Sunday default unless employer-confirmed. |
| MoSa's Hotbox | Three most recent calculated periods are Monday–Sunday with Thursday pay dates; older test periods are inconsistent | Seed the recent Monday–Sunday/Thursday pattern into the test ledger, marked production-inferred. Reconfirm at test-to-live cutover. Do not use the older inconsistent periods as the schedule source. |
| Cornerstone Payroll | Company says biweekly, but committed period lengths and boundaries are inconsistent | Preserve biweekly frequency and use manual-date mode. Do not infer an automatic period anchor. |
| Shimizu Technology | Company says biweekly; only one committed period is available and it spans Friday–Friday | Preserve biweekly frequency and use manual-date mode. Do not infer an automatic period anchor. |

The current overtime calculator assumes a Sunday workweek. The migration may preserve Sunday as a `legacy_system_default` so existing calculations do not change unexpectedly, but the UI must distinguish that from an employer-confirmed workweek.

### 2.7 Pay-run purpose must be explicit

Each payroll run must have a purpose separate from correction lifecycle state:

- `regular`;
- `off_cycle_tips`;
- `bonus`;
- `commission`;
- `correction`;
- `final`;
- `adjustment`; or
- another controlled value added through a versioned migration.

Each run also stores whether it includes ordinary base salary. A non-regular run defaults to `includes_base_salary = false` unless the operator deliberately selects and confirms otherwise.

Spike pay period #43 will be labeled as an off-cycle tips run without changing its existing financial totals. It will not generate salary, scheduled time, or additional work hours.

### 2.8 Employment termination needs an effective-dated workflow

The application already stores `employees.status` and `employees.termination_date`, but the current Terminate action automatically sets the termination date to the day the action is clicked. Reactivation clears that current date. This is not sufficient when an employee's actual last day differs from the date Cornerstone records the change, and it does not preserve a complete terminate/reactivate history.

The replacement workflow will preserve both:

- **effective date:** the actual date the employment termination or reactivation took effect; and
- **recorded evidence:** when the action was entered, who entered it, and the optional business context.

The termination effective date is required and defaults to today. An authorized operator may backdate it to the confirmed actual date, but not before the employee's hire date. An optional last-worked date records cases where the person stopped working before employment formally ended. Optional reason category and internal notes support operations without requiring sensitive narrative. Notes are permission-restricted and excluded from ordinary payroll, tax, SWICA, employee-facing, and client exports.

Termination is a status transition, not deletion. It does not erase or recalculate payroll, automatically issue final pay, or prevent a dated final/correction payroll. Reactivation records another event rather than deleting the prior termination event. A W-2/1099 classification transition is a separate linked filing-record workflow and must never be treated as an employment termination.

## 3. Proposed data responsibilities

The exact table names may change during implementation, but these responsibilities must remain separate.

### Company pay schedule

- frequency;
- effective start/end dates;
- period-boundary rule;
- pay-date rule or manual-date mode;
- timezone;
- source (`operator_confirmed`, `production_inferred`, or `legacy_system_default`);
- confirmation status and confirmer; and
- audit history.

### Company legal workweek

- starting weekday;
- starting local time;
- effective start/end dates;
- source and confirmation status; and
- audit history.

### Employee overtime and schedule profile

- pay basis (`hourly` or `salary`);
- W-2/1099 classification remains separate from pay basis;
- overtime status (`exempt`, `nonexempt`, or `needs_review`);
- exemption category/reason and effective date where applicable;
- standard weekly hours;
- daily schedule;
- timekeeping mode (`imported`, `manual`, or `schedule_with_exceptions`); and
- effective dates and audit history.

### Employee employment-status event

- event type (`terminated` or `reactivated`);
- prior and resulting status;
- required effective date;
- optional last day actually worked;
- recorded timestamp and actor;
- optional controlled reason category;
- optional restricted internal notes;
- source/audit metadata; and
- immutable history retained after reactivation.

`employees.status` and `employees.termination_date` remain the current-state snapshot used by existing screens and reports. The event history is the durable source for explaining how that snapshot changed.

### Daily/workweek time record

- work date and workweek key;
- scheduled hours;
- actual worked hours;
- PTO and holiday hours;
- overtime allocation where applicable;
- source/import provenance;
- confirmation or override evidence; and
- uniqueness rules that prevent correction or off-cycle runs from duplicating the same work date.

### Payroll run

- run purpose;
- whether ordinary base salary is included;
- earning-period dates and pay date;
- links to the workweek/time records represented by the run; and
- correction/replacement relationships.

## 4. Historical backfill policy

### AIRE

1. Create Krystel's effective-dated Monday–Friday, 8-hours-per-day remote schedule.
2. Generate schedule-based daily records beginning March 1, 2026 unless a different hire/effective date is supplied.
3. Aggregate those dates naturally into workweeks and semimonthly periods; do not assign a generic 86.67 as actual time.
4. Do not duplicate March 1–15 time for both the voided original period and its replacement period.
5. Record PTO, holiday, unpaid-time, or other deviations when supplied.
6. Create an audit entry describing the source, scope, operator, effective date, and assumptions.
7. Do not change historical salary gross, taxes, or net pay solely because time records were added.

### Spike

- No salary backfill is required because Spike has no active salary employees.
- Relabel the historical tips-only run through a migration or controlled service without recalculation.

### MoSa

- Do not backfill salary hours into the existing parallel/test ledger.
- Apply the completed schedule and timekeeping configuration to the clean live ledger at cutover.
- QuickBooks remains authoritative until the documented cutover gates are satisfied.

### Other clients

- Do not backfill salary time without an identified salary employee, confirmed effective schedule, and documented source.

## 5. Client cloning and clean cutover

The requested experience is a **Clone client setup** action, not an unrestricted database copy.

### What the clone should carry forward

- company contact and address configuration;
- departments;
- active employee profiles selected for carry-forward;
- current pay rates, wage-rate labels, and salary settings;
- W-4/W-9 and contractor settings, subject to permission controls;
- recurring payroll additions/deductions;
- payroll fields and mappings;
- pay schedule, workweek, and employee schedule configuration;
- time-tracking and payroll-intake mappings where safe;
- check layout and operational preferences; and
- an explicit link to the source ledger and clone audit event.

### What the clone must not carry forward as ordinary live data

- pay periods and payroll items;
- checks, payment settlements, or print history;
- YTD aggregate rows treated as authoritative balances;
- filings, filing statuses, transmittals, or filing evidence;
- liabilities, deposits, reconciliations, or journal postings;
- time-entry/import transaction history;
- corrective-payroll chains;
- audit logs as if they occurred in the new ledger; or
- test-only report artifacts.

### Values that require deliberate handling

- **EIN:** The current database requires a unique company EIN. A second company cannot simply receive MoSa's existing EIN. The preferred design keeps one company/legal employer and creates separate test/live payroll ledgers beneath it.
- **Employee SSNs and bank data:** These may be copied only inside the application for the same legal employer, with super-admin authorization and a security audit event. They must never be exposed in clone previews or logs.
- **Check number:** Continue or explicitly reset based on the real bank/check-stock workflow; never reset silently.
- **Historical/YTD balances:** MoSa will not use a midyear opening-balance shortcut. The intended path is to import and reconcile every authoritative pay period for the current year and the selected prior years. Opening balances remain only a controlled fallback for an unrecoverable historical gap.

### Recommended payroll-ledger model

For the same legal employer, the safe long-term model is:

- one company/legal employer identity containing the EIN and filing identity;
- one or more linked payroll ledgers marked `test`, `parallel`, `live`, or `archived`;
- exactly one live ledger for a legal employer at a time;
- filing/YTD reports read only from authoritative reconstructed history plus subsequent live payroll; and
- test/parallel transactions never enter official filing totals.

The recommended implementation keeps one MoSa company and EIN, shares its current employee/configuration data, and creates a clean payroll ledger with no pay periods. This is safer than duplicating the entire company. The UI may still present the action as **Clone client setup** or **Start clean payroll ledger**.

MoSa's current ledger should remain parallel/test history. The eventual live ledger will receive the authoritative historical reconstruction and then continue with live payroll. The existing test transactions must never enter official filing totals.

### MoSa full-history reconstruction

MoSa intends to process every pay period for the current year and the selected prior years before cutover. Therefore:

1. Historical paychecks are imported as authoritative snapshots from QuickBooks/final payroll records; they are not recalculated using current employee settings or current tax logic.
2. Revel hours and MoSa tip/loan workbooks may enrich and cross-check the import, but they do not override authoritative final paycheck, tax, deduction, or net-pay values without a reviewed reconciliation decision.
3. Periods are imported oldest to newest by pay date within each year so YTD and annual reporting can be rebuilt deterministically.
4. Voids, replacements, corrections, tips-only runs, contractor checks, and off-cycle payrolls retain their original relationships and purpose.
5. Historical snapshot periods contribute to employee history, YTD, W-2GU, 941, SWICA, and payroll reports, but do not trigger payment, check printing, tax deposits, reminders, or live liability-posting actions.
6. Each year must reconcile at the employee, pay-period, quarter, and annual level before the next year becomes authoritative.
7. The existing 2025 MoSa pipeline provides reusable Revel/tip parsing and employee matching for 26 periods, but it currently destroys/rebuilds local payroll rows and recalculates payroll. It is validation groundwork, not the production historical importer.
8. Raw historical files remain outside git and are handled as confidential payroll data.

## 6. Migration and rollout guardrails

1. Migration changes must be additive first; no historical payroll amount is recalculated automatically.
2. Existing pay-period dates remain unchanged.
3. Production-derived schedule rows retain their evidence source and confidence.
4. Ambiguous schedules use manual-date mode instead of invented anchors.
5. An automatic biweekly rule requires both its start weekday and one confirmed period-start date; the date preserves the correct alternating-week parity.
5. Existing salary hours are not overwritten by the payroll worksheet.
6. Off-cycle runs cannot inherit base salary or generate schedule time by default.
7. Workweek overtime is calculated across full workweek boundaries even when a pay period splits a week.
8. Every historical backfill is idempotent and safe to run more than once.
9. Historical time is keyed by employee and work date, not copied independently into every correction payroll.
10. Backfill, clone, workweek confirmation, and override actions create audit evidence.
11. Filing and YTD reports must exclude test/parallel ledgers unless an explicit comparison view is requested.
12. The rollout starts in warning/review mode and becomes a commit blocker only after the relevant client configuration is confirmed.
13. Termination and reactivation require an effective date and create immutable status-transition evidence.
14. A termination never deletes or recalculates historical payroll, and employee eligibility for final/correction payroll is date-aware.
15. Restricted termination notes never enter tax filings, SWICA, paystubs, or ordinary exports.
16. Future-dated termination is not silently treated as already effective; scheduled termination requires an explicit later design if Cornerstone needs it.
17. Final-pay completion is derived from committed payroll records, not a manual status checkbox that can drift from payroll history.

## 7. Required tests before release

- weekly, biweekly, semimonthly, and monthly salary division remains unchanged;
- exempt salary hours do not multiply or reduce ordinary salary;
- nonexempt salary overtime is computed independently for each workweek;
- semimonthly periods split workweeks without averaging;
- schedule-with-exceptions records the default day and a deviation correctly;
- imported salary time survives reopening and rerunning payroll;
- a voided/replacement payroll does not duplicate daily time;
- an off-cycle tips run has zero base salary and zero newly generated work hours;
- AIRE stipend additions remain taxable without adding hours;
- production schedule backfill is idempotent;
- cloning copies approved setup and excludes every transactional table;
- cloned sensitive data is permission-gated and never logged;
- test/parallel ledger data is excluded from filing/YTD outputs; and
- a full-history import cannot become authoritative until each included year reconciles;
- a backdated termination is accepted only on/after hire date and reports the effective date;
- an optional last-worked date cannot be after the termination effective date;
- reactivation retains the prior termination event and records a new actor/effective date;
- terminated employees remain available for authorized dated final/correction payroll without entering later regular payroll by accident;
- classification transitions do not create employment-termination events; and
- optional termination notes are authorization-gated, redacted from logs, and excluded from tax/employee exports.

## 8. Confirmations still required before the relevant feature is activated

The implementation can begin without manual data entry, but these business facts must be confirmed before automatic scheduling or official cutover:

1. AIRE's legal workweek starting day and time.
2. Whether Krystel is exempt or nonexempt and whether March 1, 2026 is the correct schedule effective date.
3. Whether AIRE's observed 14–16 day pay lag accurately represents its intended payroll schedule and satisfies Cornerstone's compliance review.
4. MoSa's intended live payroll-period boundary, legal workweek, and Thursday pay-date rule.
5. The exact historical years MoSa will import and the authoritative source bundle available for each year.
6. Whether the existing MoSa committed period was exclusively parallel/test data and never used for payout or filing.

## 9. Consolidated implementation sequence

1. **PR 1 — Pay-run purpose, schedule foundation, and golden payroll regression harness:** effective-dated company pay schedules, legal workweeks, run purposes, production-derived migration, and a synthetic end-to-end payroll/report reconciliation scenario in CI.
2. **PR 2 — Employee lifecycle, salary timekeeping, daily allocation, and AIRE activation:** employee overtime/schedule profiles, immutable terminate/reactivate history, schedule-with-exceptions daily records, salary UI/import preservation, workweek-aware validation, and idempotent AIRE activation/backfill.
3. **PR 3 — Payroll ledgers, clean setup clone, and authoritative historical-import foundation:** ledger lineage/isolation, Clone client setup/Start clean payroll ledger, historical snapshot batches, mappings, idempotency, locking, and reconciliation workflow.
4. **PR 4 — MoSa adapter and full historical reconstruction:** 2025 validation pilot followed by the selected prior/current years, with employee/check/period/quarter/year reconciliation and controlled promotion.

Each PR includes its focused backend, frontend, migration, reporting, browser, and regression coverage. Production backfills, schedule confirmation, ledger promotion, or client clone execution do not run merely because code was deployed; each remains a separately reviewed operational action with dry-run evidence and approval.
