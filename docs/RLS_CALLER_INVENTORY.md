# M3-7 shadow-phase caller inventory

[Build plan, §2.1 and PR M3-7](MILESTONE_3_FOUNDATIONS_BUILD_PLAN_2026-11-22.md#21-postgres-rls-safely-with-rails--neon)

Cornerstone Payroll staff and client users operate on behalf of companies. Employee and AIRE callers use verified links or source credentials. Organization finance, identity and queue infrastructure retain their existing authorization paths. The primary schema has 200 classified tables: 134 directly protected, 10 protected through parent FKs, 37 exempt and 19 global. This includes the 26 tables promoted in #541, the four Milestone 3 tables, employee notes and payroll history review items. The classification test checks the live schema against [the registry](../api/lib/rls_tables.rb).

`company` uses a company selected through the existing authorization or trusted job payload. `system` is explicit cross-company access for a listed purpose. Review the application’s existing authorization and query predicates when adding a system caller. `exempt_tables_only` covers identity, organization, finance or infrastructure reads without tenant policies.

## Lead rollout

1. Confirm direct connection capacity for both web and worker and allow headroom for advisory-lock connections, maintenance and other apps. Set the primary pool budget per process using existing `DB_POOL_MAX` or `RAILS_MAX_THREADS`. The primary pool uses the new direct URL. Queue, cache and cable keep their current URLs.
2. Use the direct `MIGRATION_DATABASE_URL` as the migration owner. On a fresh environment, run the Rails migrations first: they create `payroll_employee_login_link_decision`, which the script grants. In a lead-controlled `psql` session, run [`db/rls_runtime_role.sql`](../api/db/rls_runtime_role.sql) with `ON_ERROR_STOP` enabled. Set the password at the prompt. Create the role through SQL so it receives only the declared privileges. Keep the owner connection separate and ensure `payroll_app` neither owns the schema/tables nor inherits the owner role.
3. From `api/`, run `RLS_CONTEXT_GUARD_MODE=off bundle exec rails rls:install` with the direct migration-owner URL available as `MIGRATION_DATABASE_URL`; never run it over the runtime or pooled connection. Run this during low traffic. The installer takes table locks with a three-second lock timeout. The installer commits each table’s policies separately so previously staged tables release their locks promptly. It also creates `rls_admin.rls_kill_switch` with SELECT-only runtime privileges. Existing deployments require this explicit command. Fresh Rails schema loads stage policies automatically. Check `bundle exec rails rls:status` for 144 tables with staged policies and both enforcement flags false.
4. On **both web and worker**, add `RLS_DATABASE_URL` containing a direct PostgreSQL URL for `payroll_app` on the same primary database. Keep the existing pooled `DATABASE_URL` and owner-only migration credentials. Set `RLS_CONTEXT_GUARD_MODE=log` in production and `raise` in the configured staging rehearsal. Leave `RLS_EXPECT_ENFORCED` unset in step 2. Restart the processes and check the runtime role, guard and policies with `rls:status` and production readiness. Boot verifies the runtime role and kill-switch grants when the guard is enabled.
5. Process one full pay cycle and collect warnings from both processes. Filter for `rls_missing_context` and `rls_unclassified_sql`. Export the application JSON-lines messages and feed them to `bundle exec rails rls:shadow_report < exported.log` from `api/`. It groups by event, call site and sorted table names. The event contains application stack frames, process role and request ID when available. SQL text and bind values stay out of the event. Step 3 needs a full warning-free cycle and its own enforcement window.

Before turning on enforcement (phase 3):

- `bundle exec rails rls:status` shows `login_link_decision` with `security_definer`, `row_security_off` and `owner_bypasses_rls` true, `execute_grantees` exactly the owner and `payroll_app`, `public_can_execute` and `grant_option_granted` false, and `runtime_can_execute` true.
- Production readiness passes, including "Cross-company login link decision is a restricted SECURITY DEFINER function".
- One enforced contact save works end to end: on a company 1 test employee, a same-person email confirmation saves, and a login linked to another client's employee is refused. If the function's owner ever changes, the new owner must bypass RLS; otherwise every such check fails closed.

With the guard off, Rails keeps its existing primary connection. For shadow rollback, set `RLS_CONTEXT_GUARD_MODE=off`, remove `RLS_DATABASE_URL` from web and worker and restart. Policy definitions can stay staged. After a future enforcement deploy, the owner can use the following immediate rollback before using `bundle exec rails rls:disable` over the direct owner URL. The task disables active policies table by table with a three-second lock timeout and bounded retries.

```sql
UPDATE rls_admin.rls_kill_switch
SET bypass_enabled = true, updated_at = CURRENT_TIMESTAMP, reason = 'operator incident reference'
WHERE singleton;
```

New scopes pick up the switch within five seconds per process and enter system mode. In-flight scopes retain their original settings. A protected statement that arrives without a scope logs a warning and uses system mode for that statement during bypass. Clear the switch with the same owner connection when the incident is resolved. With enforcement disabled, application authorization is the active tenant boundary. Even with enforcement enabled, system mode is intended to contain application scoping errors and is available to trusted callers within the runtime DB session.

## Enforcement window (phase 3)

Phase 3 turns the staged policies on. Hold it in its own window during low traffic, at least one full pay cycle apart from the Clerk production cutover (`M3-0b`), and never while a payroll is being calculated or checks are printing. The lead runs every production command. Run the owner commands from `api/` the same way as `rls:install`, with the direct migration-owner URL in `MIGRATION_DATABASE_URL`. Never use the runtime or pooled URL.

`OWNER` below stands for `RLS_CONTEXT_GUARD_MODE=off MIGRATION_DATABASE_URL=<direct owner URL>`.

### Pre-checks

Complete these before the window opens. Any failure postpones it.

1. **Shadow report.** Export the JSON-lines application logs from web, worker and the employee API for at least the last full pay cycle. `bundle exec rails rls:shadow_report < exported.log` must print `[]`. Scope any caller it reports before going further.
2. **Status.** `bundle exec rails rls:status` on web and on worker must show:
   - `guard_mode` of `log`;
   - `role.rolname` of `payroll_app`, with `rolbypassrls` and `rolsuper` both false;
   - `kill_switch` of `false`;
   - `enforcement.phase` of `shadow`, with `enforced_tables` at 0 of `protected_tables` and an empty `enabled_xor_forced`;
   - `policy: true` on every table;
   - `login_link_decision` as listed under "Before turning on enforcement".
3. **Readiness.** Production readiness passes with `RLS_EXPECT_ENFORCED` unset.
4. **Child companies.** The contract migration deploys whenever this PR merges, so check this against production before merging: `bundle exec rails payroll_child_companies:verify` prints `nulls=0 parent_fk=valid` for all 26 promoted children. Merge at low traffic.
5. **Kill-switch drill.** Hold an owner `psql` session open for the whole window. Set the switch with the SQL above and confirm `rls:status` reports `kill_switch: true`. Clear it and confirm `false`. Record how long each step took.

### Order

1. **Deploy the contract migration.** `ContractPayrollChildCompanies` makes `company_id` NOT NULL on the 26 promoted children. It does not depend on the window and normally ships before it, with the deploy that follows this PR's merge. For each table it adds a `CHECK (company_id IS NOT NULL) NOT VALID`, validates the check without blocking writes, then sets NOT NULL and drops the check. Each step uses a five-second lock timeout and three attempts. If any NULL remains, it refuses and names the tables. In that case, run `payroll_child_companies:backfill` and deploy again. A rerun skips the tables already contracted. Afterwards, `OWNER bundle exec rails rls:enforce DRY_RUN=1` must not mention a nullable `company_id`.
2. **Guard to `raise` on web and worker.** Set `RLS_CONTEXT_GUARD_MODE=raise` on both services and restart them. The employee API service already uses `raise`. `rls:status` then reports `guard_mode: raise`. An unscoped protected query now fails its request or job. Run the smoke tests below and watch the logs for 15 minutes. If anything fails, set the guard back to `log` and stop.
3. **Enforce in batches.**
   1. `OWNER bundle exec rails rls:enforce DRY_RUN=1` lists the tables that still need ENABLE and FORCE, in batches of 10. It refuses if the kill switch is not readable and off, if any policy is unstaged, if the login link decision is not restricted, if `payroll_app` can bypass RLS or write the switch, if the owner does not bypass RLS, or if a promoted `company_id` is still nullable.
   2. Pilot one batch: `OWNER bundle exec rails rls:enforce TABLES="<the dry run's batch 1>"`. Run the smoke tests and watch the logs for five minutes.
   3. Run the rest: `OWNER bundle exec rails rls:enforce`. The busiest payroll tables (`timecards` through `employees` and `audit_logs`) go last. Each table commits separately with a three-second lock timeout and three attempts. Five seconds separate each batch; change that with `BATCH_PAUSE` and the batch size with `BATCH_SIZE`. A table that cannot be locked is reported. Rerun the same command to resume: tables already enforced are skipped. The task checks the kill switch before every table and stops once it is set. Only one `rls:enforce` runs at a time, and `rls:disable` waits for a running one to stop. Any other error stops the run without a summary. The tables already enforced stay enforced, so read `rls:status` and rerun.
4. **Verify.**
   - The task prints `all_enforced: true` and `All protected tables are enabled and forced`.
   - `rls:status` shows `enforcement.phase` of `enforced`, with `enforced_tables` equal to `protected_tables`.
   - Set `RLS_EXPECT_ENFORCED=true` on web, worker and the employee API and restart them. Production readiness then passes, including "RLS policy installation matches the selected phase" and "RLS kill switch is off".
   - The employee app switch's database check reports `enforced`. Demo early-access windows retire on the next demo read or expiry sweep, which ends the waiver.

### Smoke tests

Run these after the guard change, after the pilot batch and after the full run. Use the test workspace or a test employee in company 1, as in the earlier enforced contact check.

- **Payroll staff.** Open the dashboard, a client's employee list, an employee profile and a pay period's payroll items. Save a draft change on a test employee.
- **Cross-company.** A staff user assigned to one client gets "not found" for another client's employee or pay period.
- **Client portal.** Open documents, messages and payroll submissions. Upload a test file.
- **Employee app.** Open pay stubs and W-2GU documents. A same-person email confirmation saves. A login linked to another client's employee is refused.
- **AIRE.** A worker statement (My Pay) request and an event post succeed.
- **Worker.** Recurring jobs run. The count of Solid Queue failed executions does not grow, and the worker heartbeat stays current.

### What to watch

- `TenantScope::MissingContextError`, `rls_missing_context` and `rls_unclassified_sql`.
- `RLS context missing` (SQLSTATE 42501) and `new row violates row-level security policy`, both `PG::InsufficientPrivilege`.
- The 5xx rate on web and the employee API, and new Solid Queue failed executions.
- Lists that come back unexpectedly empty. A missing context fails loudly, but a wrong company context returns no rows.

### Instant rollback

1. **Kill switch.** Takes seconds and needs no deploy. Set it with the SQL above from the owner session. Each process enters system mode for new scopes within five seconds, and unscoped statements log instead of raising. While the switch is on, readiness fails "RLS kill switch is off", which is expected.
2. **Disable.** `MIGRATION_DATABASE_URL=<direct owner URL> bundle exec rails rls:disable` disables RLS table by table. `rls:status` then shows `enforcement.phase` of `shadow`.
3. **Settle.** Unset `RLS_EXPECT_ENFORCED` on web, worker and the employee API. Set the guard back to `log` if the guard caused the incident, and restart. Confirm `rls:status` shows `enforcement.phase` of `shadow` before clearing the kill switch, with a reason.

The contract migration does not need rolling back. NOT NULL is independent of enforcement, and the fill triggers keep supplying `company_id` on insert.

## Nullable company IDs

The schema audit reconciled every nullable `company_id` against the expand migration and the policy registry.

| Tables | Meaning of NULL |
| --- | --- |
| `pay_component_tax_rules` | A shared reference rule available to all company scopes. The staged SELECT policy exposes shared and same-company rules. Separate INSERT, UPDATE and DELETE policies require company ownership or explicit system mode. |
| `audit_logs` | An organization or authentication event. These records remain visible only in system mode. |
| `finance_books`, `invoice_chat_sessions`, `invoice_recipients`, `invoices`, `work_hour_client_links` | Optional company links to organization-scoped data. These tables remain exempt and keep their organization or finance book authorization. |

The 26 [promoted children](../api/db/migrate/support/m3_7_child_companies.rb) no longer allow NULL. The contract migration requires `company_id` after the backfill. The global reference and framework tables in the registry carry no `company_id`. The parent-protected tables derive ownership from their declared relationships.

## HTTP controllers

Paths in this table are relative to `api/app/controllers/`. The base callbacks cover record lookups, the action, serializers, audit callbacks and action-level exception handlers. The portal failure audit uses a narrow system block because it can run before authentication or after a company scope has closed. Streamed CSV exports open a system scope for each authorized batch. Clerk authentication and MFA run before business scoping. An accepted invitation checks MFA against the locked Payroll user before the system-scoped binding write. MFA denial is an organization security audit written in system mode without opening company scope.

| Controller file | RLS mode |
| --- | --- |
| `api/v1/admin/aire_history_approvals_controller.rb` | `company` via base scope. |
| `api/v1/admin/aire_payroll_calendars_controller.rb` | `company` via base scope. |
| `api/v1/admin/aire_payroll_cockpits_controller.rb` | `company` via base scope. |
| `api/v1/admin/annual_retirement_limits_controller.rb` | `exempt_tables_only` for the global reference read. `system` for updates and organization audit. |
| `api/v1/admin/audit_logs_controller.rb` | `system` for organization events and authorized company events. |
| `api/v1/admin/base_controller.rb` | `company` by default. `system` for organization finance and its audit. |
| `api/v1/admin/check_numbers_controller.rb` | `company` via base scope. |
| `api/v1/admin/check_print_generations_controller.rb` | `company` via base scope. |
| `api/v1/admin/check_print_runs_controller.rb` | `company` via base scope. |
| `api/v1/admin/check_register_controller.rb` | `company` via base scope. |
| `api/v1/admin/checks_controller.rb` | `company` via base scope. |
| `api/v1/admin/client_documents_controller.rb` | `company` via base scope. |
| `api/v1/admin/client_inbox_controller.rb` | `system` across the staff user’s authorized companies. |
| `api/v1/admin/client_operating_profiles_controller.rb` | `company` from the authorized route company. |
| `api/v1/admin/client_profitability_controller.rb` | `system` for org profitability across clients. |
| `api/v1/admin/companies_controller.rb` | `system` for authorized company administration, cloning and promotion. |
| `api/v1/admin/company_assignments_controller.rb` | `system` for managing assignments and org audit. |
| `api/v1/admin/departments_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_bulk_imports_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_change_requests_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_document_requirements_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_hours_evidence_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_intake_settings_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_loans_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_notes_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_payroll_fields_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_retirement_elections_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_retirement_year_inputs_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_time_records_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_wage_rates_controller.rb` | `company` via base scope. |
| `api/v1/admin/employee_work_profiles_controller.rb` | `company` via base scope. |
| `api/v1/admin/employees_controller.rb` | `company` via base scope. |
| `api/v1/admin/expense_payments_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/expense_vendors_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/expenses_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/filing_submitters_controller.rb` | `company` via base scope. |
| `api/v1/admin/finance_api_tokens_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/finance_books_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/finance_overviews_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/general_transmittals_controller.rb` | `company` via base scope. |
| `api/v1/admin/historical_imports_controller.rb` | `company` via base scope. |
| `api/v1/admin/historical_paycheck_adjustments_controller.rb` | `company` via base scope. |
| `api/v1/admin/historical_reports_controller.rb` | `company` via base scope. |
| `api/v1/admin/imported_pay_periods_controller.rb` | `company` via base scope. |
| `api/v1/admin/invoice_billing_profiles_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/invoice_chat_sessions_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/invoice_credit_notes_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/invoice_payments_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/invoice_receivables_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/invoice_recipients_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/invoice_recurrences_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/invoice_send_schedules_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/invoices_controller.rb` | `system` via admin finance scope. |
| `api/v1/admin/non_employee_checks_controller.rb` | `company` via base scope. |
| `api/v1/admin/organizations_controller.rb` | `system` for organization administration and audit. |
| `api/v1/admin/pay_component_tax_rules_controller.rb` | `company` via base scope. |
| `api/v1/admin/pay_period_excluded_employees_controller.rb` | `company` via base scope. |
| `api/v1/admin/pay_periods_controller.rb` | `company` via base scope. |
| `api/v1/admin/pay_schedule_settings_controller.rb` | `company` via base scope. |
| `api/v1/admin/pay_stubs_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_entry_resolutions_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_fields_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_filing_records_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_filing_responsibilities_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_final_records_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_go_live_controller.rb` | `system` for setup comparisons and transfers between authorized companies. |
| `api/v1/admin/payroll_history_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_history_review_items_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_imports_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_intake_imports_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_items_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_liabilities_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_liability_center_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_reminder_configs_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_standing_changes_controller.rb` | `company` via base scope. |
| `api/v1/admin/payroll_submission_periods_controller.rb` | `company` via base scope. |
| `api/v1/admin/portal_file_requests_controller.rb` | `company` via base scope. |
| `api/v1/admin/portal_messages_controller.rb` | `company` via base scope. |
| `api/v1/admin/portal_notification_recipients_controller.rb` | `company` via base scope. |
| `api/v1/admin/portal_threads_controller.rb` | `company` via base scope. |
| `api/v1/admin/printer_profile_selections_controller.rb` | `company` via base scope. |
| `api/v1/admin/printer_profiles_controller.rb` | `company` via base scope. |
| `api/v1/admin/prior_provider_histories_controller.rb` | `company` via base scope. |
| `api/v1/admin/punch_entries_controller.rb` | `company` via base scope. |
| `api/v1/admin/record_activities_controller.rb` | `company` via base scope. |
| `api/v1/admin/reports_controller.rb` | `company` via base scope. |
| `api/v1/admin/tax_configs_controller.rb` | `company` via base scope. |
| `api/v1/admin/tax_year_readiness_controller.rb` | `company` via base scope. |
| `api/v1/admin/time_tracking_imports_controller.rb` | `company` via base scope. |
| `api/v1/admin/time_tracking_source_health_controller.rb` | `company` via base scope. |
| `api/v1/admin/time_tracking_sources_controller.rb` | `company` via base scope. |
| `api/v1/admin/timecard_imports_controller.rb` | `company` via base scope. |
| `api/v1/admin/timecards_controller.rb` | `company` via base scope. |
| `api/v1/admin/user_invitations_controller.rb` | `company` via base scope. |
| `api/v1/admin/users_controller.rb` | `system` for user administration and audit. |
| `api/v1/admin/year_end_controller.rb` | `system` for clients overview. `company` for checklist and write actions. |
| `api/v1/auth_controller.rb` | `system` for verified user’s links and accessible company capabilities. |
| `api/v1/cable_tickets_controller.rb` | `exempt_tables_only` for authorized, one-time ticket issuance. |
| `api/v1/client/base_controller.rb` | `company`. |
| `api/v1/client/departments_controller.rb` | `company` via base scope. |
| `api/v1/client/documents_controller.rb` | `company` via base scope. |
| `api/v1/client/employee_change_requests_controller.rb` | `company` via base scope. |
| `api/v1/client/employee_document_requirements_controller.rb` | `company` via base scope. |
| `api/v1/client/employee_intake_settings_controller.rb` | `company` via base scope. |
| `api/v1/client/employees_controller.rb` | `company` via base scope. |
| `api/v1/client/imported_pay_periods_controller.rb` | `company` via base scope. |
| `api/v1/client/pay_periods_controller.rb` | `company` via base scope. |
| `api/v1/client/pay_stubs_controller.rb` | `company` via base scope. |
| `api/v1/client/payroll_submission_periods_controller.rb` | `company` via base scope. |
| `api/v1/client/portal_file_requests_controller.rb` | `company` via base scope. |
| `api/v1/client/portal_messages_controller.rb` | `company` via base scope. |
| `api/v1/client/portal_threads_controller.rb` | `company` via base scope. |
| `api/v1/client/reports_controller.rb` | `company` via base scope. |
| `api/v1/companies_controller.rb` | `system` for counts across accessible companies. |
| `api/v1/employee_portal/base_controller.rb` | `system` for the verified user’s link lookup after MFA. `company` from the authorized link. |
| `api/v1/employee_portal/context_controller.rb` | `company`. |
| `api/v1/finance/access_controller.rb` | `system` after finance book-token checks, including org audit. |
| `api/v1/form_500s_controller.rb` | `company` for the selected and authorized payroll period. |
| `api/v1/integrations/aire/cutoff_changes_controller.rb` | `system` for authenticated period discovery, then `company` for the cutoff change. |
| `api/v1/integrations/aire/events_controller.rb` | `system` for authenticated source discovery in the receiver, then `company` for receipt and dispatch. |
| `api/v1/integrations/aire/worker_statements_controller.rb` | `system` for credential matching, then `company` for statements and audit. |
| `api/v1/notification_settings_controller.rb` | `system` for authorized delivery history and organization-level audit. |
| `api/v1/public/tenant_branding_controller.rb` | `system` for the public subdomain registry cache fill, exposing public branding only. |
| `application_controller.rb` | `exempt_tables_only` for base identity context. `system` for invitation binding and session audit. |
| `health/dependencies_controller.rb` | `exempt_tables_only` for database and queue health probes. |

## Cable

| Caller | RLS mode |
| --- | --- |
| `ApplicationCable::Connection` | `exempt_tables_only` for ticket consumption and authorization. `system` for a denied MFA attempt’s organization audit. |
| `ApplicationCable::Channel` | `exempt_tables_only` for base connection accessors. |
| `ClientPortalThreadChannel` | `exempt_tables_only` for subscribe and delivery rechecks. Broadcast serialization uses `company` from the thread, or an existing `system` scope for a batch. |
| `ClientInboxChannel` | `exempt_tables_only` for organization membership and a data-free invalidation stream. |

## Jobs

Paths are relative to `api/app/jobs/`. The scope covers Active Job deserialization, execution and retry/discard handlers. A standalone record-ID job uses trusted queued IDs in system mode. When an existing tenant runs such work inline, its company scope continues to constrain the lookup.

| File | RLS mode |
| --- | --- |
| `aire_history_operation_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `aire_manual_allocation_sync_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `aire_payroll_acknowledgement_dispatch_job.rb` | `system` for batch, clone or dispatch work. |
| `aire_payroll_calendar_delivery_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `aire_payroll_calendar_dispatch_job.rb` | `system` for batch, clone or dispatch work. |
| `aire_payroll_calendar_source_refresh_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `aire_payroll_entry_status_sync_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `aire_payroll_event_verification_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `aire_payroll_status_sync_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `application_job.rb` | `exempt_tables_only`. |
| `check_print_generation_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `check_print_generation_recovery_job.rb` | `system` for batch, clone or dispatch work. |
| `client_document_scan_recovery_job.rb` | `system` for batch, clone or dispatch work. |
| `connected_payroll_job.rb` | `exempt_tables_only`. |
| `expire_practice_portal_access_job.rb` | `system` for batch, clone or dispatch work. |
| `generate_client_document_preview_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `historical_client_bootstrap_dispatch_job.rb` | `system` for batch, clone or dispatch work. |
| `invoice_recurrence_dispatch_job.rb` | `exempt_tables_only`. |
| `invoice_send_dispatch_job.rb` | `exempt_tables_only`. |
| `invoice_send_job.rb` | `exempt_tables_only`. |
| `migration_rehearsal/clone_job.rb` | `system` for batch, clone or dispatch work. |
| `ocr_process_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `portal_notification_dispatch_job.rb` | `system` for batch, clone or dispatch work. |
| `portal_upload_cleanup_job.rb` | `system` for batch, clone or dispatch work. |
| `queue_durability_probe_job.rb` | `exempt_tables_only`. |
| `quickbooks_history/client_bootstrap_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `quickbooks_history/cutover_verification_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `revoke_payroll_access_job.rb` | `exempt_tables_only`. |
| `scan_client_document_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `send_payroll_reminders_job.rb` | `system` for batch, clone or dispatch work. |
| `send_user_invite_email_job.rb` | `exempt_tables_only`. |
| `sync_effective_compensation_job.rb` | `system` for batch, clone or dispatch work. |
| `tax_work_hours_import_job.rb` | `exempt_tables_only`. |
| `tax_work_hours_nightly_refresh_job.rb` | `exempt_tables_only`. |
| `test_workspace/clone_job.rb` | `system` for batch, clone or dispatch work. |
| `time_tracking_correction_receipt_job.rb` | `system` for the queued ID, existing `company` when called inline in a tenant scope. |
| `training_replay/clone_job.rb` | `system` for batch, clone or dispatch work. |
| `year_end_efile_check_job.rb` | `company` from the queued company argument. |

### Recurring scheduler entries

| Entry | Job or command | RLS mode |
| --- | --- | --- |
| `expire_practice_portal_access` | `ExpirePracticePortalAccessJob` | `system` |
| `retry_portal_upload_cleanups` | `PortalUploadCleanupJob` | `system` |
| `sync_effective_compensation` | `SyncEffectiveCompensationJob` | `system` |
| `send_payroll_reminders` | `SendPayrollRemindersJob` | `system` |
| `refresh_tax_work_hours` | `TaxWorkHoursNightlyRefreshJob` | `exempt_tables_only` |
| `create_recurring_invoice_drafts` | `InvoiceRecurrenceDispatchJob` | `exempt_tables_only` |
| `dispatch_scheduled_invoice_emails` | `InvoiceSendDispatchJob` | `exempt_tables_only` |
| `dispatch_aire_payroll_acknowledgements` | `AirePayrollAcknowledgementDispatchJob` | `system` |
| `dispatch_aire_payroll_calendar_sync` | `AirePayrollCalendarDispatchJob` | `system` |
| `dispatch_historical_client_bootstraps` | `HistoricalClientBootstrapDispatchJob` | `system` |
| `recover_abandoned_check_print_generations` | `CheckPrintGenerationRecoveryJob` | `system` |
| `recover_pending_client_document_scans` | `ClientDocumentScanRecoveryJob` | `system` |
| `dispatch_portal_notifications` | `PortalNotificationDispatchJob` | `system` |
| `clear_solid_queue_finished_jobs` | `SolidQueue::Job.clear_finished_in_batches` | `exempt_tables_only` |

## Cross-company and other scoped services

| Caller | RLS mode |
| --- | --- |
| `year_end/input_revision.rb` | `company` for a single company, `system` for authorized batches. An existing system reader keeps its scope. Includes payroll history review items. |
| `YearEnd::ClientsOverview` | `system` for grouped year-end status across the user’s accessible companies. |
| `audit_log_presenter.rb` | `system` for standalone authorized multi-company preloads. Reuses the caller’s `company` or `system` scope for presenting logs. |
| `ClientInboxQuery` | `system` through the client inbox controller, with per-company authorization predicates. |
| `TenantSubdomainRegistry` | `system` on the effective registry cache fill, used by CORS, Clerk origin verification and public branding. |
| `AirePayrollEvents::Receiver` | `system` for source authentication, `company` for the authenticated event. |
| `StagingCloneContainment` | `system` for quarantine, configuration and validation of a contained staging clone. `exempt_tables_only` for queue schema probes. The clone manifest is staging infrastructure. |
| `EncryptedDataReadiness`, `ProductionReadiness`, `StagingReadiness` | `system` for across-company encrypted reads and integration destinations. `exempt_tables_only` for dependency probes. |
| `PayrollAccess::SessionRevoker`, `CableTicketService` | `exempt_tables_only` for revocation and connection handshakes. Ticket denial audits use `system` via `MfaPolicy`. |
| M3-4 compensation writers, wage-rate versions and history reader | `company` during staff/client payroll setup, with existing `system` scope for authorized clone and reconciliation flows. |
| Client operating profile updates and parity checks | `company` for edits and lookups. `system` for operator parity checks and registry discovery. |
| `PayrollHistoryReview` detection and resolution | `company` for admin review and the operator detector. `system` for grouped year-end reads. |
| M3-8 request telemetry, process roles, shared rate limiting and queue health | `exempt_tables_only` for telemetry, Solid Queue and cache probes. The tenant-origin registry has its own scope. |

## Rake tasks

| Task | RLS mode |
| --- | --- |
| `aire_lock_rollout:configure` | `system` |
| `aire_lock_rollout:preview_historical_imports` | `system` |
| `aire_rollout:apply` | `system` |
| `aire_rollout:configure_categories` | `system` |
| `aire_rollout:ensure_complete` | `system` |
| `aire_rollout:export` | `system` |
| `aire_rollout:preview` | `system` |
| `clerk:cutover:apply` | `system` |
| `clerk:cutover:build_import` | `exempt_tables_only` |
| `clerk:cutover:build_manifest` | `exempt_tables_only` |
| `clerk:cutover:dry_run` | `exempt_tables_only` |
| `clerk:cutover:inventory` | `exempt_tables_only` |
| `clerk:cutover:preflight` | `exempt_tables_only` |
| `clerk:cutover:rollback` | `system` |
| `clerk:jwks:clear` | `exempt_tables_only` |
| `compensation:lint_writes` | `exempt_tables_only` |
| `compensation:reconcile_rollout` | `system` |
| `compensation:sync_effective` | `system` |
| `connected_payroll:status` | `exempt_tables_only` |
| `db:clear_advisory_locks` | `exempt_tables_only` |
| `db:integrity` | `exempt_tables_only` |
| `db:safe_prepare` | `exempt_tables_only` |
| `e2e:seed` | `system` |
| `employees:decrypt_contractor_eins` | `system` |
| `employees:encrypt_contractor_eins` | `system` |
| `mosa:rebuild` | `system` |
| `operating_profiles:parity` | `system` |
| `operations:queue_probe:cleanup` | `exempt_tables_only` |
| `operations:queue_probe:enqueue` | `exempt_tables_only` |
| `operations:queue_probe:replay` | `exempt_tables_only` |
| `operations:queue_probe:status` | `exempt_tables_only` |
| `payroll:fica_legacy:inventory` | `system` |
| `payroll:fica_legacy:reconcile_imports` | `system` |
| `payroll:fica_legacy:recover` | `system` |
| `payroll:fica_legacy:review_sources` | `system` |
| `payroll:legacy_check_voids` | `system` |
| `payroll:legacy_employer_benefits:inventory` | `system` |
| `payroll:legacy_empty:apply` | `system` |
| `payroll:legacy_empty:preview` | `system` |
| `payroll_child_companies:backfill` | `system` |
| `payroll_child_companies:verify` | `system` |
| `payroll_history_review:detect` | `company` |
| `payroll_liabilities:backfill` | `system` |
| `production:readiness` | `system` |
| `quickbooks_history:import` | `system` |
| `rls:disable` | `exempt_tables_only` |
| `rls:enforce` | `exempt_tables_only` |
| `rls:install` | `exempt_tables_only` |
| `rls:shadow_report` | `exempt_tables_only` |
| `rls:status` | `exempt_tables_only` |
| `solid_queue:setup` | `exempt_tables_only` |
| `staging:clone:configure` | `system` |
| `staging:clone:quarantine` | `system` |
| `staging:clone:verify` | `system` |
| `staging:readiness` | `system` |
| `timekeeping:aire_salary_backfill` | `system` |
| `year_end:wage_impact` | `system` |

Rails schema tasks and `rls:install`, `rls:enforce` and `rls:disable` operate on catalog or DDL through the owner connection. The status and shadow report tasks inspect metadata or exported events. Operational scripts accessing protected data use their matching scoped Rake entry point.

The Rake re-audit traced task calls into their services. `mosa:rebuild` scopes tenant payroll and compensation writes including employees, deduction types and employee deductions. `production:readiness` enters system scope for the open pay-period scan and the other readiness probes that span companies. Clerk inventory and dry-run use identity tables, and the import builder only reads files. Clerk apply and rollback retain system mode for audit writes. Queue probes use operational and Solid Queue tables. Staging readiness and containment open scopes in their services. Owner schema tasks run with the guard off.

## Verification boundary

The backend suite defaults to guard mode `raise`. Request and Active Job entry points and `:rls` examples have no implicit tenant scope. Legacy fixture setup and direct unit calls use the test owner exemption. The isolation spec uses direct sessions and temporarily enables the staged policy in a rollback-only test transaction. CI's transaction-lock lane uses a real PgBouncer service in transaction mode, separate from session-based tenant scoping. The production shadow run is still needed to observe live callers and direct-connection usage.
