# Record creation and history QA

Base: `5d8deabce58597882061a5d3b7cf49c8d4132d04` (`origin/main`, verified November 15, 2026). Worktree: `/Users/agent/work/cp-record-history`, branch `feat/record-history`.

Cornerstone staff manage Guam payroll clients, practice workspaces, employees and pay runs. The existing `RecordActivityQuery`, `RecordActivitiesController`, and `RecordActivityTimeline` already supported employee and pay-period activity. Client Management uses `/api/v1/companies`, separately from admin company detail responses. Both staff company payloads now include batched creator information. Portal payloads exclude it. No production access or real payroll files were used.

## Acceptance and evidence

Agent-executed affected-flow QA used the local Rails API and Vite app with disposable Postgres databases and synthetic factory data. The shared T3 browser uses Playwright/Chromium. Desktop: 1440px; phone layout: 375px. WebKit/mobile Safari was not run because WebKit cannot start on this host. Resizing does not establish real-device behavior.

| Acceptance | Result | Evidence |
| --- | --- | --- |
| A: creation audit | Passed | Transactional model audit for companies, employees and native pay periods. Request coverage for company creation, test workspace creation, manual/portal employee creation; bulk employee import assertion; model actor/rollback tests. Existing user invitation transaction/audit retained and its request specs run. Related correction/import services run. |
| B: Client Management attribution | Passed | New client and practice workspace show Morgan Auditor with date; synthetic pre-tracking client shows Unknown (before tracking). Staff summaries preload creators and fetch legacy creation evidence in a batch. |
| C: histories and link | Passed | Expanded company/practice panels, client edit History section, employee Activity and pay-run Activity show creator and events. Company panel link followed to Activity History: record type=companies, record ID=2, company ID=2, one matching event. |
| D: request authorization | Passed | Same-company staff allowed; foreign record denied; portal and unauthenticated callers denied. Portal company response excludes creator data. Exact creation evidence must belong to the record's company. |
| E: frontend states | Passed | Creator known/unknown; timeline loading/empty/list/error/retry/pagination; collapsed panel does not mount history until opened. |
| F: responsive | Passed | Clients with expanded practice history, employee Activity and pay-run Activity checked at 1440px and 375px. `document.documentElement.scrollWidth <= innerWidth` throughout. Filtered Activity History checked at 375px. |

Screenshots:

- `clients-1440.png`: production clients and expanded practice workspace history.
- `clients-375.png`: phone layout, attribution, unknown legacy creator and expanded workspace history.
- `employee-375.png`: employee Activity with creator and event.
- `pay-run-1440.png`: pay-run Activity with creator and event.
- `activity-filter-375.png`: filtered Activity History reached from company panel. This earlier capture predates the final company creation verb mapping; its filter and layout are unchanged.

The first synthetic practice-copy attempt failed because a factory employee's department belonged to a different company. After fixing that synthetic association and retrying the copy, the workspace reached ready. No business-code repair was needed. Creation and subsequent copy-service audit events are both retained.

## Validation commands

API uses `TEST_DATABASE_URL=postgres://localhost:5432/cp_test_record_history`. Database setup: `RAILS_ENV=test bundle exec rails db:create db:schema:load`, followed by `db:migrate` for migration verification. A separate `cp_history_qa` database held browser fixtures.

- `cd api && bundle exec rubocop`
- `cd api && bundle exec rspec spec/models/{record_creation,record_creator}_spec.rb spec/requests/api/v1/company_creators_spec.rb spec/requests/api/v1/admin/{record_activities,audit_logs,companies,test_workspaces,pay_periods,employees,users}_spec.rb spec/requests/api/v1/client/employees_spec.rb spec/services/employee_bulk_import/import_service_spec.rb spec/services/pay_period_correction_service_spec.rb spec/services/issue_corrective_paycheck_service_spec.rb spec/services/time_tracking/late_hours_run_service_spec.rb spec/services/quickbooks_history/client_bootstrap_apply_service_spec.rb`
- `cd api && bundle exec brakeman -q`
- `cd web && npm ci`
- `cd web && DEPLOYMENT_ENV=production VITE_DEPLOYMENT_ENV=production npm run gate` (same build flags as quality CI; creates a local build only).
- Impeccable advisory scan of the new creator/panel components returned `[]`.

Final related API run: 394 examples, 0 failures. Frontend gate: 185 test files and 1,819 tests passed, with typecheck, lint and build passing. RuboCop: no offenses; Brakeman: zero warnings.

Full API suite was not run; the related request, model and service suite was selected for this change. Build output retains the existing large-chunk warning. Test output includes existing jsdom scroll/navigation warnings.

## Migration and limits

`20261115080000_add_record_creators.rb` adds nullable bigint `created_by_id` columns to companies and employees, with no default or data update. Native pay periods already had this column. It builds all three creator indexes concurrently, outside a DDL transaction. Adding each column takes a brief PostgreSQL ACCESS EXCLUSIVE lock and can wait behind existing transactions; there is no table rewrite. Concurrent index builds permit normal reads/writes but consume I/O and can wait on transactions. No foreign key validation scan or creator backfill is performed.

Existing exact creation events can prove old attribution. Other old records stay unknown. Native ActiveRecord creation is audited inside its transaction; future bulk SQL paths must explicitly record creation because they bypass callbacks. Historical pay-period snapshots are a separate model and remain a follow-up. Org-level user history is not enabled by this endpoint; invitation auditing already exists. Adding a type requires an explicit scoped registry entry and authorization decision.

Next types in priority order: checks/check-print runs; employee loans and loan transactions; client/employee documents and portal file requests; historical pay-period/paycheck snapshots and import batches; payroll submissions/intake sessions; departments and pay schedules; organization-level users/access assignments.

The lifecycle helper could not initialize: `Invalid machine profile: schema_version must be 1`. Exact task server sessions and browser tab were tracked manually. Existing account Postgres was borrowed; protected home services were untouched. Servers/browser are stopped and both disposable databases dropped before handoff. The source worktree is retained for the lead's review; merge/deploy are not authorized for this worker.
