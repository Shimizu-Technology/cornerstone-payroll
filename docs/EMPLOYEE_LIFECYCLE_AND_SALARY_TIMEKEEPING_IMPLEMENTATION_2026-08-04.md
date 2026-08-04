# Employee Lifecycle and Salary Timekeeping Implementation

**Implementation date:** August 4, 2026
**Status:** Implemented on a stacked, unmerged feature branch; production activation has not occurred
**Depends on:** PR 1 pay-schedule, legal-workweek, pay-run-purpose, and golden-regression foundation
**Design:** [Pay Schedules, Salary Timekeeping, and Client Cloning](PAY_SCHEDULE_SALARY_TIMEKEEPING_AND_CLIENT_CLONE_DESIGN_2026-08-03.md)

## Why this exists

Cornerstone needs salary hours for recordkeeping and overtime review without changing correct ordinary salary math. It also needs employment termination dates to reflect when a change actually took effect, not merely when an accountant clicked a button. Historical payroll, tax classifications, and corrections must remain explainable rather than being rewritten.

This implementation establishes four separate histories:

1. a worker's W-2/1099 filing classification;
2. effective-dated salary/timekeeping and overtime rules;
3. immutable employment status transitions; and
4. daily time evidence linked to the payroll items that used it.

Keeping these histories separate prevents a salary schedule, termination, or contractor transition from silently changing prior payroll or filing results.

## Data and audit rules

### Employee work profiles

Each profile stores its effective range, pay basis, overtime status, exemption evidence where applicable, standard weekly hours, normal daily schedule, timekeeping method, source, confirmer, confirmation timestamp, and restricted setup note.

- A new profile closes the prior profile the day before the new effective date.
- Profiles cannot overlap or rewrite historical payroll snapshots.
- `salary` does not imply `exempt`.
- An exempt profile requires a documented category and reason.
- A nonexempt salary profile remains salary-paid but receives separately calculated workweek overtime.
- `needs_review` is deliberately not treated as an exemption. It blocks a payroll allocation that would otherwise contain overtime.
- Managers and organization administrators can create profiles and see restricted setup notes. Accountants may review the nonrestricted configuration but cannot change it or see the restricted note.

### Employment status events

Termination and reactivation create immutable events containing the effective date, prior/resulting status, actor, recorded timestamp, source, and optional business context.

- Termination effective date is required and cannot predate hire or be future-dated.
- Last worked date is optional and cannot be after the termination date.
- Reason category and internal notes are optional.
- Internal notes are restricted to managers and organization administrators and do not enter payroll, tax, SWICA, paystub, or ordinary export data.
- Reactivation adds another event and clears only the employee's current termination snapshot. It does not remove the prior event.
- The legacy one-click delete/terminate endpoint now refuses the action and directs callers to the explicit workflow.
- Client users cannot bypass the workflow through ordinary employee updates.

### Daily time records and revisions

Daily records distinguish scheduled hours, actual worked hours, PTO, and holiday hours. They retain the work date, legal-workweek key, source, ledger key, and revision lineage.

- Schedule-with-exceptions creates the confirmed daily schedule only for eligible dates.
- A schedule is never applied before its profile effective date. If multiple profiles split the legal workweeks intersecting one payroll, calculation stops for operator review instead of silently mixing overtime rules.
- Actual worked hours override schedule-derived worked hours for that day.
- PTO and holidays remain separately visible and are not counted as hours worked for overtime.
- A correction requires a reason, supersedes the current record, and creates a new revision.
- Daily history cannot be edited in place or deleted.

### Payroll time allocations

Each allocation links a payroll item to the current daily records represented by that run.

- Regular runs with base salary can materialize confirmed scheduled time.
- Full void-and-redo correction runs with base salary reference the same daily dates and do not duplicate the daily ledger.
- Voided originals remain historical but are excluded from the AIRE backfill target.
- Supplemental corrective checks and nonregular runs without base salary do not invent schedule time.
- Allocations are keyed by payroll item, date, daily record, and ledger so a later ledger-isolation PR can separate authoritative, parallel, test, and historical workflows.

## Payroll calculation behavior

For an exempt salary employee, scheduled/worked hours are informational. Ordinary base pay still follows the configured annual, per-period, or variable salary rule.

For a nonexempt salary employee, including a variable salary with a confirmed per-period override:

1. the allocator loads complete seven-day workweeks intersecting the pay period;
2. it allocates only dates inside the pay period to that payroll item;
3. it identifies hours above 40 within each fixed workweek; and
4. it adds salary overtime using the configured weekly salary equivalent and standard weekly hours.

This prevents a semimonthly boundary from averaging or double-counting a split workweek. It also preserves imported/manual salary hours when no confirmed schedule profile exists.

Payroll eligibility is date-aware. A worker terminated during a regular period is still eligible for that period; a later regular period excludes the worker. If the worker is later reactivated, payrolls wholly inside the inactive gap remain excluded and the reactivation date begins the new eligible interval. Final, correction, and adjustment workflows may include a terminated worker deliberately. Prior paychecks and reports are never recalculated merely because a status event was recorded.

## Reporting behavior

- Payroll item snapshots retain the profile, workweek, timekeeping source, and schedule used for the calculation.
- Payroll registers use stored salary hours instead of assuming 80 hours.
- Existing manually imported salary hours remain visible after reopen/rerun.
- Salary overtime flows through gross pay and employee YTD totals.
- Termination notes and work-profile setup notes are excluded from ordinary report payloads.

## AIRE / Krystel controlled activation

The production task is intentionally not a migration that runs during deploy. It requires an exact company ID, employee ID, exact expected employee name, confirmed effective date, and manager/admin actor ID. A name mismatch or a target outside the specified company stops the task.

The first command is always a dry run:

```sh
COMPANY_ID=<id> EMPLOYEE_ID=<id> EXPECTED_EMPLOYEE_NAME='<exact name>' EFFECTIVE_ON=<yyyy-mm-dd> ACTOR_USER_ID=<id> bundle exec rake timekeeping:aire_salary_backfill
```

After the preview and approvals are retained, the same exact command may be run with `APPLY=true`. Application is transactional and idempotent. It:

- creates the Monday–Friday, 8-hours-per-day schedule-with-exceptions profile when no conflicting profile exists;
- keeps overtime status as `needs_review` until AIRE/Cornerstone confirms exempt versus nonexempt treatment;
- targets committed regular or full correction-replacement payroll items that included base salary;
- excludes voided originals and off-cycle/supplemental runs;
- reuses one current daily record per worker/date/ledger;
- populates schedule/worked hours and allocation evidence; and
- compares all protected money columns before and after every item, rolling back if gross, net, tax, or deduction money changed.

No production command has been executed as part of this PR. Before application, retain the dry-run output, confirm database restore readiness, verify the effective date and legal workweek, obtain Leon and Cornerstone approval, and capture post-run payroll-register/report reconciliation.

## Deployment and rollback

The schema migration is additive. Existing payroll rows keep their current money and can operate without a work profile; the system does not globally assign 40/80/86.67 hours to legacy salary employees.

Recommended order:

1. merge and deploy the PR 1 foundation;
2. merge and deploy this PR after local/PR approval;
3. verify migrations and ordinary payroll reads with no production backfill;
4. confirm AIRE's legal workweek, Krystel's effective date, and overtime status;
5. retain and approve the exact-target dry run;
6. take/confirm a restorable backup and execute the approved apply command; and
7. reconcile hours, protected money, payroll register, SWICA/quarterly data, and audit evidence.

If the operational backfill must be reversed, do not delete history casually. Restore from the pre-run backup or use a separately reviewed compensating migration/service that removes only the exact generated allocations/daily records/profile while proving payroll money remains unchanged.

## Verification gate

The branch must pass:

- work-profile validation and authorization/redaction tests;
- termination/reactivation service and request tests;
- daily-record immutability and revision tests;
- regular, off-cycle, correction, idempotency, nonexempt overtime, and AIRE dry-run/apply allocation tests;
- salary calculator, correction-service, report, date-aware eligibility, and canonical golden payroll regression tests;
- full backend suite plus static/security checks;
- frontend typecheck, lint, and production build; and
- desktop and mobile browser checks for profile setup, daily-time review, termination, and floating employee actions.

The exact command results and PR review outcome belong in the pull request. Passing tests authorizes review; it does not authorize merging, deploying, or running the production backfill.

## Deferred work

This PR does not clone MoSa, create payroll ledgers, or import historical QuickBooks payroll. Those remain PR 3 and PR 4 work so test/parallel payroll can be isolated from authoritative filings before MoSa history is promoted.
