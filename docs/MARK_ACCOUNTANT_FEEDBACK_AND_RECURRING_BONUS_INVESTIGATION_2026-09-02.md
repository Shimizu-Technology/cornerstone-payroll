# Mark accountant feedback and recurring bonus investigation

**Reviewed:** September 2, 2026  
**Owners:** Shimizu Technology and Cornerstone Tax Services  
**Status:** Production incident root cause confirmed; P0 fix implemented and verified on branch; not merged or deployed; production was inspected read-only

## Purpose

This document combines three related reviews:

1. what Cornerstone Payroll is, why it exists, and how its payroll lifecycle works;
2. Mark's accountant-role feedback, mapped to what is built and what still needs work; and
3. the production incident in which one employee's June 4 bonus appears on the employee profile but not on the payroll register, while a comparison employee's bonus appears correctly.

This is the investigation record, implementation assessment, and release plan. The P0 code and regression coverage described below exist on branch `codex/mark-feedback-sara-bonus-review`. They are not merged, deployed, or operationally verified in production.

## Executive conclusion

Mark's feedback is legitimate. Some requests describe features that already exist but are hard to find or use correctly. Others expose real gaps in the product's loan, retirement, garnishment, audit, and approval controls. The recurring-bonus incident is a confirmed payroll defect, not a Render configuration problem and not a failed calculation request.

The immediate findings are:

- The reported employee's taxable bonus is saved on the employee profile.
- The June 4, 2026 pay period is still `calculated`, not approved or committed.
- The reported employee's payroll item contains five older non-taxable recurring adjustments but does not contain the bonus.
- The comparison employee's payroll item contains the expected taxable bonus.
- Mark saved both profiles and successfully recalculated the open June 4 period multiple times. Render logs and application audit records show successful requests; no application error explains the missing bonus.
- The code only copies employee defaults when the payroll item's entire adjustment array is empty. One existing adjustment blocks every later employee-default change. The reported item already had five adjustments, so its new bonus was skipped. The empty comparison item qualified as unset and received its bonus.
- The current production backend is commit `b4e9e64`. Commit `8906749` failed during its pre-deploy database task and never became live. The relevant payroll-default code is unchanged between those revisions.

No production records, configuration, deployments, or services were changed during this review.

## P0 implementation status

The branch now contains the minimum safe correction for the confirmed defect:

- draft and calculated payroll items refresh employee defaults whenever the item has not been manually overridden;
- approved and committed payroll items keep their historical snapshots;
- clearing all employee defaults clears a stale, non-overridden open-period snapshot;
- every payroll creation/recalculation path uses the same synchronization method, including normal runs, manual item recalculation, payroll intake, MoSa/Revel import, time-tracking import, and timecard OCR;
- a client that explicitly submits payroll adjustments marks the item as manually overridden before synchronization;
- editing unrelated fields in the payroll-item modal no longer resends the adjustment array and accidentally freezes future defaults;
- the employee form distinguishes recurring defaults from one-time payroll adjustments and explains the open-period behavior; and
- the payroll-item modal labels its bonus as one-time and explains when a manual override is created.

The deidentified release fixture now mirrors the decisive production shape: synthetic employee Bonus Alpha starts with five fictional reimbursements on an existing June 4 item, then receives a `$1,234.56` employee default; synthetic employee Bonus Beta starts empty, then receives an `$876.54` employee default. The accountant browser test recalculates the same period, verifies both bonuses and Bonus Alpha's `$2,034.56` gross, reruns it, and verifies the bonus is not duplicated. These fixture amounts and labels are intentionally different from production.

This implementation does not change the reported employee's production payroll. The separate accounting confirmations and controlled correction steps in this document remain required after review and deployment.

## What Cornerstone Payroll is

Cornerstone Payroll is a Guam-focused, multi-client payroll operating system for Cornerstone Tax Services. It is intended to replace a fragmented process in which source exports, spreadsheets, manual review, QuickBooks, checks, compliance preparation, and staff knowledge lived in different places.

The core product is the controlled payroll lifecycle:

```text
organization and client setup
  -> employee and pay configuration
  -> hours, salary, tips, loans, and adjustment intake
  -> gross-to-net calculation
  -> payroll register and exception review
  -> approval
  -> commit
  -> checks, pay stubs, liabilities, and reports
  -> quarterly and annual compliance preparation
  -> retained audit evidence
```

The application includes:

- multiple client companies under one accounting-firm organization;
- company-scoped employees, departments, pay schedules, payroll fields, and loans;
- hourly, salary, variable-salary, and contractor payroll;
- Guam withholding, Social Security, Medicare, Additional Medicare, retirement, tips, deductions, and employer contributions;
- imports from client source systems and payroll evidence;
- calculated, approved, committed, corrected, and voided payroll states;
- checks, pay stubs, transmittals, payroll registers, liability records, and tax-preparation reports;
- company assignment, role-based access, and audit events; and
- supporting firm tools such as Invoice Center and General Transmittals.

It is not a complete general ledger, bank-reconciliation system, benefits-administration platform, child-support compliance engine, or automated filing service. Those boundaries matter when deciding whether a request is a small payroll enhancement or a separate operational subsystem.

The implementation is a React/Vite frontend deployed on Netlify and a Rails API deployed on Render with PostgreSQL-backed payroll state and a background worker. The frontend is a workflow surface; the Rails API is authoritative for company scope, payroll math, lifecycle transitions, immutable committed records, and permissions.

## How employee defaults and payroll snapshots are intended to work

Employee profiles contain reusable defaults. A payroll item is the employee's period-specific snapshot. This separation is necessary because a committed paycheck must remain explainable even if the employee's settings change later.

There are two distinct concepts:

- **Recurring employee default:** something expected to recur in future payrolls, such as a recurring reimbursement, stipend, or deduction.
- **One-time payroll input:** something that applies to one check, such as a single bonus for the June 4 payroll.

When a pay-period item is first created, the app copies employee defaults into that item. The period item can then be changed independently. Once manually changed, it is marked as overridden so later profile changes do not silently erase the period-specific decision.

That snapshot boundary is correct. The current all-or-nothing synchronization rule is not.

## Mark's feedback: exact implementation assessment

| Mark's request | What he is asking for | Current state | What needs to happen | Priority |
| --- | --- | --- | --- | --- |
| Simple or straight loan deductions | Deduct a recurring amount without pretending Cornerstone is tracking an original balance or maturity schedule | **Functionally available, poorly modeled in the UI.** A post-tax recurring adjustment or company payroll field can do the paycheck math. The `EmployeeLoan` screen requires an original amount, so it is the wrong surface for a no-balance deduction. | Add an explicit `Recurring deduction / balance not tracked` option, or rename and guide the existing payroll-field workflow so accountants do not create a fake installment loan. Preserve separate reporting from balance-tracked loans. | P2 |
| Installment loans | Track original balance, payment per payroll, remaining balance, additions, final capped payment, and payoff history | **Core is built; end-to-end operations are incomplete.** `EmployeeLoan` has original/current balance, scheduled payment, payment/addition history, suspend/reactivate, payoff capping, and paid-off state. The MoSa import and payroll-field matching paths are not yet a trustworthy automatic ledger integration, and there is no explicit maturity/end-date workflow. | Finish explicit loan modes, reliable payroll-field linkage, import preview/matching, idempotent commit-time ledger posting, unmatched-loan warnings, maturity/end-date handling, reconciliation reports, and production validation. | P2 |
| 401(k) catch-up | Support an additional catch-up election and make sure annual limits are handled correctly | **Ordinary 401(k) deductions and reporting are built; catch-up compliance is not.** The app supports pre-tax/Roth percentages, fixed payroll fields, employer contributions, W-2GU grouping, YTD totals, and reports. It does not implement age/election eligibility, tax-year limits, catch-up buckets, automatic caps, or stop/restart behavior. | Model plan/election type, tax-year limits, catch-up eligibility and limit, YTD remaining amount, automatic capping, clear register/pay-stub reporting, and accountant override/audit rules. Validate annually against current official limits before use. | P2 |
| Child support | Deduct child support and make payment/remittance understandable | **Basic plumbing exists; a complete child-support workflow does not.** Payroll fields support a `child_support` category, payee/reference metadata, liabilities, and standalone child-support checks. There is no complete order/case model, effective dates, priority rules, protected/disposable earnings limits, arrears, fee handling, remittance allocation, or proof-of-payment workflow. | Build a dedicated order record and calculation/remittance workflow, or explicitly scope v1 to accountant-entered fixed deductions with warnings and manual compliance review. Do not imply the generic field is a compliance engine. | P2 |
| Separate first and last name columns | Make lists/registers easier to sort and compare with source files | **Data model is built; presentation is incomplete.** First and last names are stored separately, while several operational tables render one combined full-name cell. | Add separate sortable columns where accountants reconcile payroll, without changing stored names or check/pay-stub display. Keep a combined display in compact/mobile views. | P1 |
| Fully hide the sidebar | Recover working space on wide payroll registers | **Partially built.** The sidebar collapses to a narrow rail but does not fully disappear. | Add true hide/show behavior, a reliable reopen control/shortcut, persisted preference, and mobile-safe overlay behavior. | P1 |
| Totals at the bottom of columns | See and reconcile column totals without leaving the register | **Core totals exist; coverage and table behavior are incomplete.** The system totals standard payroll values and exports totals, but dynamic/custom payroll columns and wide-table footer alignment are not consistently complete or sticky. | Define which monetary/hour columns must total, calculate totals from the same server-authoritative dataset, add totals for dynamic payroll fields, and keep the footer aligned during horizontal scrolling. | P1 |
| Separate Medicare amounts | Distinguish employee Medicare, employer Medicare, and Additional Medicare | **Calculation/storage is built; presentation needs clarification.** Employee and employer Medicare are separate values in the backend. Additional Medicare is also separate. Some UI/report surfaces make the distinction harder to see. | Label and display all three explicitly wherever Mark reconciles payroll. Preserve the correct rates: employee Medicare `1.45%`, employer Medicare `1.45%`, and Additional Medicare `0.9%` over the applicable threshold. Do not implement `0.09%`. | P1 |
| Audit trail | Let an accountant see who changed payroll and when | **Audit logging is built; accountant access is intentionally restricted.** Organization-wide audit history belongs to organization administrators. Mark's accountant role cannot access that global administration surface, even though his production actions are recorded. | Keep the organization-wide audit log restricted. Add a company-scoped payroll activity/history view or report for accountants, excluding organization administration, secrets, unrelated clients, and sensitive workforce notes. | P2 |
| Easier pay-stub access | Open or download a worker's pay stub directly from the operational workflow | **Built but not discoverable enough.** Pay-stub generation and download paths exist. | Add a one-click pay-stub action on the payroll row, checks/payments view, and employee payroll history, with lifecycle-aware disabled states and no duplicate generation side effects. | P1 |
| Accountant role behavior | Let Mark do real payroll work for assigned clients | **Built as designed.** Accountants can maintain employees and perform assigned-client payroll operations, including calculate, approve, commit, checks, corrections, and reports. They cannot administer users, tax configuration, integration secrets, or organization-wide audit history. | Keep the scope boundary. Decide separately whether Cornerstone needs preparer/reviewer segregation. Today the same authorized accountant can calculate, approve, and commit the same run. | P2 decision |
| Recurring bonus does not reach the register | Make a saved employee bonus appear when an open payroll is recalculated | **Confirmed defect.** Existing nonempty payroll adjustment snapshots never refresh from the employee default, even when they have not been manually overridden. | Fix the default synchronization rule, clarify recurring versus one-time entry, add open-period stale-default warnings, test the production-shaped regression, and reconcile the June 4 run under review control. | **P0** |

## Accountant role interpretation

Mark is a production `accountant`, and the observed actions are consistent with the approved role matrix. The application audit trail shows him updating both relevant employees, recalculating the June 4 payroll, and generating report previews/PDFs.

The role is not intended to be read-only. It is an assigned-client payroll operator. That makes his ability to update employee payroll setup and rerun payroll legitimate.

The current role model does not enforce separation of duties. If Cornerstone wants one person to prepare and another to approve or commit, that requires a separate product control:

- persist the preparer and reviewer;
- block self-approval/self-commit where policy requires it;
- define emergency override authority;
- record override reason and audit evidence; and
- test the rule in both API and UI.

Changing Mark to a manager or administrator would not solve the defect and would grant unnecessary configuration or organization access.

## June 4 recurring-bonus incident

### Reported behavior

Cornerstone reported that one employee's bonus could be seen on the employee profile but did not appear in the June 4 payroll register. A second employee's bonus, created through the same general workflow, appeared correctly.

### Production evidence

The following facts were verified directly against production in read-only mode:

| Evidence | Reported employee | Comparison employee |
| --- | --- | --- |
| Profile default | Active taxable bonus present | Active taxable bonus present |
| Profile update | Saved before repeated recalculation | Saved before recalculation |
| June 4 payroll item | Existing item with prior adjustments | Existing item with no prior adjustments |
| Dedicated `bonus` column | Unused; recurring value belongs to the adjustment snapshot | Unused; recurring value belongs to the adjustment snapshot |
| Period adjustment snapshot | Five non-taxable reimbursements; no bonus | Taxable bonus present |
| Manual adjustment override marker | Not set | Not set |
| Calculated gross | Excludes the saved bonus | Includes the saved bonus |

The bonus living in `payroll_adjustments` rather than the separate `bonus` column is expected for an employee recurring default. The defect is that the reported employee's recurring bonus is absent from the period snapshot.

The affected pay period has:

- pay date: June 4, 2026;
- purpose: regular payroll;
- status: `calculated`;
- an existing payroll item for each relevant employee.

The application audit trail and Render logs establish the sequence:

1. Mark updated the reported employee.
2. Mark ran the affected payroll successfully.
3. The result still omitted the reported bonus.
4. Mark updated the comparison employee.
5. Mark ran the same payroll successfully.
6. The comparison bonus appeared.
7. Mark updated the reported employee again and reran payroll; the reported bonus still did not appear.

Render recorded repeated POST requests to the affected period's `run_payroll` endpoint during the investigation window. Application audit records show HTTP 200 responses. There is no exception, timeout, authorization failure, or worker failure associated with this symptom. Exact record identifiers, timestamps, compensation values, and employee details remain outside the repository in the access-controlled production system.

### Confirmed root cause

The problem is in `PayrollItem#apply_default_payroll_adjustments_if_unset!`:

```ruby
def apply_default_payroll_adjustments_if_unset!(source_employee = employee)
  return if payroll_adjustments.present? || payroll_adjustments_overridden?

  defaults = self.class.normalize_payroll_adjustments(source_employee&.default_payroll_adjustments)
  self.payroll_adjustments = defaults if defaults.present?
end
```

The method is called when payroll is run or an item is recalculated. It returns as soon as a payroll item has **any** adjustment. It does not ask whether the item was manually overridden, whether the employee default changed, or whether one new default is missing.

The reported item already had five recurring reimbursements. Its array was therefore nonempty, so every recalculation skipped the new bonus. Its override marker was not set, which means the system had no evidence that those five entries were period-specific manual edits.

The comparison item qualified as unset when the default was first applied, so the exact same method copied its bonus. This is why the workflow appeared inconsistent even though the server followed the same branch every time.

### Contributing product issue

The employee screen calls these values **Employee-Specific Recurring Adjustments** and says they are copied into new payroll runs. The June 4 item already existed and had been calculated before the bonus was added.

Cornerstone therefore needs two clear workflows:

- **One-time bonus for this check:** enter it on the open payroll item using the dedicated Bonus field or an explicit one-time taxable adjustment.
- **Recurring bonus for future checks:** save it on the employee profile, then explicitly review whether it should also be applied to existing draft/calculated periods.

The current UI makes it too easy to save a recurring default while expecting an existing period to update.

### Payroll consequence

The reported employee's current gross pay excludes the taxable bonus. If the bonus is confirmed as additional compensation for this period and no other input changes, gross pay must increase by the confirmed bonus amount, followed by a complete recalculation of withholding, Social Security, Medicare, employer taxes, retirement/payroll fields, deductions, and net pay.

This is not a display-only defect. The bonus is absent from the period data used by the calculator and reports.

### Required accounting confirmation

A separate retirement-configuration question was found on the reported employee's production profile. Its exact election, amount, and employer configuration are intentionally not recorded in source control. Because it may materially change the resulting check, Cornerstone must resolve it from the access-controlled production record before correction.

Before correcting the June 4 payroll, Cornerstone must confirm:

1. whether the bonus is one-time or recurring;
2. whether the configured retirement deduction is intended for this same payroll;
3. whether the deduction is ordinary deferral, catch-up, or another plan contribution;
4. whether YTD/plan limits permit it; and
5. whether the resulting check, taxable wages, and employer contribution match Mark's intended result.

## Correct fix design

### 1. Repair default synchronization

For the existing data model, the safe release rule is:

```ruby
return if payroll_adjustments_overridden?
return unless open_period?

if known_default_snapshot? || empty? || legacy_snapshot_is_subset_of_current_defaults?
  self.payroll_adjustments = normalize(employee.default_payroll_adjustments)
  mark_as_default_snapshot
end
```

In other words, a draft/calculated item refreshes when it is a known employee-default snapshot, is empty, or is a legacy snapshot whose complete adjustment multiset still appears in the employee's current defaults. The last condition matches the production incident: the period item contained the five existing defaults and the employee profile contained those same five plus the newly added bonus. Multiplicity is preserved when comparing entries, so duplicate-looking adjustments are not collapsed.

Every newly copied default snapshot now records `payroll_adjustments_source: employee_default` in `custom_columns_data`; an explicit period edit records `payroll_adjustments_source: manual` together with `payroll_adjustments_overridden`. This provenance lets later default changes and removals refresh safely. An older unmarked, nonempty array that cannot be proven to be defaults is preserved rather than overwritten. That conservative legacy rule means an old default that was replaced wholesale cannot be identified automatically; it requires explicit review because the pre-fix data has no trustworthy source marker.

This is safer than merging by label in the current JSON array because labels are editable and not stable identifiers. Assigning an empty normalized array remains necessary for known default snapshots so removing all employee defaults clears a stale open-period snapshot.

The method should be renamed to reflect synchronization rather than “apply if unset.” Every caller must be reviewed, including normal payroll runs, item recalculation, MoSa import, time-tracking import, payroll intake, and timecard OCR.

### 2. Preserve the immutable history boundary

- Only draft and calculated periods may refresh defaults.
- Approved or committed periods must not change silently.
- A committed-period correction must use the correction workflow and retain the original snapshot.
- Manual period adjustments must remain protected by the override marker.
- Reapplying imports must not erase explicitly imported or manual period data.

### 3. Add explicit stale-default UX

When an accountant changes payroll-affecting employee defaults while an open payroll exists, show:

- which draft/calculated periods may be stale;
- a preview of additions, changes, and removals;
- whether each affected item has a manual override;
- an explicit `Apply to open payroll` action; and
- a clear statement that approved/committed payrolls require a correction workflow.

For a single check, the payroll item editor should say `One-time for this payroll`. The employee profile should say `Recurring for future payrolls`.

### 4. Improve long-term provenance

The current JSON adjustment entries have no stable ID or source version. A durable follow-up should add:

- stable adjustment ID;
- source type and source ID;
- source/default version or updated timestamp;
- copied-at timestamp;
- per-entry manual override state; and
- audit metadata for default synchronization.

That enables a true three-way merge: update unchanged defaults, preserve manual period edits, and surface conflicts rather than relying on an all-or-nothing array flag.

## Regression and acceptance coverage

The P0 release must cover all of these cases. Items marked automated are enforced on this branch; operational items remain release checks:

1. **Automated:** an existing payroll item with old defaults receives a newly added taxable bonus on rerun.
2. **Automated:** changing a default refreshes a non-overridden item.
3. **Automated:** removing all defaults clears a non-overridden draft/calculated item.
4. **Automated:** a manually overridden item keeps its period-specific adjustments.
5. **Automated:** an unmarked legacy period adjustment that cannot be proven to be an employee default is preserved.
6. **Automated:** an approved or committed period does not change through ordinary default synchronization.
7. **Covered by existing calculator/import suites:** salary and import-owned inputs remain intact while adjustments synchronize.
8. **Automated:** timecard OCR updates an existing item through the shared synchronization path.
9. **Automated in the release lane and existing payroll suites:** the register/calculator uses the synchronized taxable bonus, and the broader export/report suites guard downstream outputs.
10. **Automated:** gross and taxes are recalculated from updated period data, rather than changing display data only.
11. **Automated:** the production-shaped Bonus Alpha/Bonus Beta fixture reproduces the old failure and passes with the fix.
12. **Existing control:** recalculation remains recorded through the run-payroll audit event; per-adjustment provenance is a separate long-term improvement.
13. **Automated:** repeating recalculation leaves one bonus entry and does not duplicate it.
14. **Automated browser request assertions:** editing then reverting an adjustment, or adding then removing a blank row, does not transmit an unchanged adjustment array or mark the item manual.

## Operational correction plan for June 4

No correction was performed during this investigation. After the accounting confirmations above and after a code fix is reviewed, Cornerstone should:

1. export and retain the current June 4 register as before-change evidence;
2. confirm that the affected period is still calculated and has not been used as a finalized external source;
3. decide whether the bonus is one-time or recurring;
4. apply the amount to the reported employee's period item explicitly, or use the reviewed default-sync action;
5. recalculate the reported employee and the period;
6. compare before/after gross, taxable wages, FIT/Guam withholding, Social Security, Medicare, 401(k), employer contribution, deductions, and net pay;
7. inspect the register, pay stub, check preview, retirement report, and transmittal preview;
8. have a second authorized reviewer confirm the result;
9. approve/commit only after reconciliation; and
10. retain the incident and correction evidence in the audit trail.

If the period becomes committed before correction, do not edit it in place. Use a supplemental/corrective payroll linked to the original item.

## Separate production deployment blocker and branch fix

The most recent backend deployment, commit `8906749`, failed before startup. The build completed successfully. The pre-deploy command then ran:

```text
bundle exec rails db:safe_prepare && bundle exec rails solid_queue:setup
```

`db:clear_advisory_locks` found two “stale” connections, called `pg_terminate_backend`, and then received:

```text
ActiveRecord::ConnectionFailed: terminating connection due to administrator command
SSL connection has been closed unexpectedly
```

The task is unsafe for a pooled Neon/PgBouncer connection because it enumerates backend PIDs and later terminates them across separate queries. A pooled connection can move between physical backends, and the blanket `state != 'active'` cleanup can kill legitimate web/worker sessions. In this deployment it caused the migration process to lose its database connection.

This did not cause the bonus defect. It did leave production on the older revision and blocks a reliable bonus-fix release.

The deployment repair should:

- remove automatic termination of every idle/non-active application connection;
- run migrations through a direct, unpooled database URL when the provider supports it;
- serialize pre-deploy migrations to one release process;
- use bounded lock/statement timeouts and controlled retry;
- target a verified migration advisory-lock holder only under strict application-name/age criteria, if forced termination remains necessary;
- re-establish the connection before retrying after any provider-side disconnect; and
- test that the cleanup task can never terminate its own current backend or ordinary live web/worker sessions.

The branch replaces the session-termination task with an aborting compatibility guard and adds `db:safe_prepare`, which launches `db:prepare` and `solid_queue:setup` through explicitly supplied direct migration URLs. In production it fails closed when `MIGRATION_DATABASE_URL` is absent or points at a recognized pooler. It maps shared cache, queue, and cable databases to the same direct URL and accepts separate direct migration URLs for split databases. Whenever a migration URL is configured—and therefore on every permitted production run—the runner applies fixed PostgreSQL connection, lock, statement, and idle-transaction timeouts.

The Docker runtime entrypoint no longer prepares schemas during web-server startup; schema changes belong only to the serialized pre-deploy phase. Render receives the direct migration URL as a service secret because that platform runs the configured pre-deploy command for the service. Kamal keeps every `MIGRATION_*_DATABASE_URL` out of `config/deploy.yml`'s runtime secret list and uses the active `.kamal/hooks/pre-deploy` hook to pass them only to the version-pinned, primary-host one-off migration container. Tests prove the old task cannot open a database connection, recognized pooled migration URLs are rejected, every shared schema task receives only direct migration connections, the Kamal runtime configuration excludes direct migration URLs, the hook invokes the safe task exactly once, and runtime startup cannot invoke a schema task.

### Render configuration required after merge

Do not change production configuration before the reviewed code is available. For the first deployment of this branch:

1. In the Neon project, copy the direct connection string for the production database. It must not contain `-pooler` in the hostname.
2. Add it to the Render backend service as the secret `MIGRATION_DATABASE_URL`. Keep the existing pooled `DATABASE_URL` for normal web and worker traffic.
3. If cache, queue, or cable use a different physical database, configure its direct URL as `MIGRATION_CACHE_DATABASE_URL`, `MIGRATION_QUEUE_DATABASE_URL`, or `MIGRATION_CABLE_DATABASE_URL`. No separate values are needed while they share the primary database.
4. Set the Render pre-deploy command to exactly:

   ```text
   bundle exec rails db:safe_prepare
   ```

   Do not append `solid_queue:setup`; `db:safe_prepare` already runs it through the direct connection.
5. Deploy the reviewed commit and require a successful pre-deploy log before promoting it. The old live revision remains serving if pre-deploy fails.
6. Confirm the expected commit is live on both web and worker services. Then perform the deidentified smoke test before any June 4 correction.

Never restore automatic `pg_terminate_backend` cleanup. If a future migration is blocked, identify the exact holder and coordinate a maintenance window rather than killing every idle application connection.

## Branch verification evidence

Local evidence was current as of `2026-09-02T15:23:21Z`. Earlier GitHub Actions runs [33642423339](https://github.com/Shimizu-Technology/cornerstone-payroll/actions/runs/33642423339) and [33643328863](https://github.com/Shimizu-Technology/cornerstone-payroll/actions/runs/33643328863) independently passed the backend, frontend, and browser gates on prior reviewed heads. The current implementation must receive the same independent current-head result after it is pushed.

- `bundle exec rails db:safe_prepare` against a local test database, including Solid Queue setup;
- runtime-entrypoint regression proving web-server startup performs no schema preparation;
- full Rails suite after review fixes: `1,885 examples, 0 failures`;
- Brakeman: `0 security warnings`;
- Bundler Audit: `No vulnerabilities found`;
- npm audit: `0 vulnerabilities` after advancing the affected transitive development dependency to its patched release;
- frontend typecheck, ESLint, and production build;
- focused model/request/pre-deploy coverage for open-period synchronization, provenance, legacy manual preservation, immutable states, timecard OCR, database-session safety, and one-off Kamal migration scope; and
- the complete seven-test Gate 0 browser release lane, including the accountant-role Bonus Alpha/Bonus Beta scenario and request assertions that unrelated or reverted payroll-item edits do not transmit or freeze the adjustment snapshot.

A separate manual Chrome walkthrough against a disposable local database confirmed the recurring-versus-one-time guidance, six adjustment rows on the existing-adjustments fixture, both fictional bonuses, the expected synthetic gross, and exactly one bonus after recalculation. Changing only overtime preserved the bonus and left the manual-adjustment override unset.

Local Vite emitted a Node version warning because the workstation shell was on Node `22.0.0`; the repository declares Node `22.22.3`, and the typecheck, lint, build, and browser suite still passed. CI remains the authoritative clean-environment check on the declared version.

## Recommended implementation order

### P0 — Payroll correctness and deployability

1. Fix the unsafe pre-deploy database cleanup and prove one clean preview/production-style migration run.
2. Add the default-adjustment synchronization regression tests.
3. Implement the minimal safe synchronization rule and review every caller.
4. Add recurring-versus-one-time copy and stale-open-period warning.
5. Validate a deidentified existing-adjustments/empty-adjustments scenario end to end.
6. Deploy, verify the live commit, and perform the controlled June 4 reconciliation.

### P1 — Accountant workflow clarity

1. Separate first and last name columns on reconciliation views.
2. Add a fully hidden sidebar mode.
3. Complete/stick register totals, including dynamic payroll fields.
4. Split Medicare labels and totals consistently.
5. Add direct pay-stub actions where accountants work.

### P2 — Controls and domain completeness

1. Add a client-scoped accountant activity history without exposing organization administration.
2. Decide and implement preparer/reviewer segregation if Cornerstone requires it.
3. Finish explicit no-balance versus balance-tracked loan modes and MoSa reconciliation.
4. Build 401(k) catch-up/annual-limit controls.
5. Build the scoped child-support order and remittance workflow.

## Release and acceptance gates

The work is not complete when code is merged. Acceptance requires:

- focused model/request tests and the full payroll regression suite passing;
- a clean Render deploy with the expected commit live on both web and worker services;
- no production mutation during diagnosis;
- a deidentified browser test of the exact stale-default scenario;
- a reviewed before/after June 4 register;
- confirmation of the reported employee's bonus and retirement intent;
- no duplicate or missing adjustment on repeated recalculation;
- correct register, check, pay-stub, report, liability, tax, and YTD results; and
- named Cornerstone reviewer signoff before commit.

## Evidence map

Key code and authority documents reviewed:

- `README.md`
- `docs/PRODUCT_STRATEGY_AND_PLATFORM_BOUNDARIES_2026-08-23.md`
- `docs/ROLE_PERMISSION_MATRIX_2026-05-14.md`
- `docs/PRODUCTION_FOLLOWUP_ROADMAP_2026-03-29.md`
- `docs/PAYROLL_FIELDS_AND_REPORTING_PLAN_2026-05-25.md`
- `docs/MOSA_LOANS_AND_IMPORT_WORKFLOW_PLAN_2026-05-20.md`
- `api/app/models/payroll_item.rb`
- `api/app/controllers/api/v1/admin/pay_periods_controller.rb`
- `api/app/controllers/api/v1/admin/payroll_items_controller.rb`
- `api/app/services/payroll_calculator.rb`
- `api/app/services/salary_payroll_calculator.rb`
- `api/app/models/employee_loan.rb`
- `api/lib/tasks/db_unlock.rake`
- `web/src/pages/employees/EmployeeForm.tsx`
- `web/src/components/payroll/PayrollItemEditModal.tsx`
- `web/src/pages/PayPeriodDetail.tsx`

Production evidence reviewed read-only:

- employee default adjustment snapshots for the reported and comparison employees;
- June 4 pay period and payroll-item snapshots;
- item/profile timestamps and override metadata;
- application audit records for Mark's accountant actions;
- Render request logs for the affected payroll recalculations;
- live and failed Render deployment revisions; and
- the failed pre-deploy log.

Sensitive employee data encountered in the production UI is intentionally excluded from this document.
