# Postgres RLS enforcement readiness

**Verdict on 2026-11-26: not ready for the production cutover.** The owner-side shadow baseline is verified and both code fixes passed local rehearsal. Merge and deploy the reviewed fixes, collect clean log evidence for a complete pay cycle, and finish the per-service runtime and post-pay-run preflight before changing production. [Code fixes and verification](https://github.com/Shimizu-Technology/cornerstone-payroll/pull/626). The [runbook](RLS_ENFORCEMENT_RUNBOOK.md) is for the subsequent post-pay-run window.

The audit used `origin/main` at `89db891eb7d634bf9ed97870694633e6b34b6af8`. The initial DB task rehearsal used `42f6f59ce`. The intervening reports and UI changes did not change the schema, the policies or the RLS tasks. Staff and clients operate in an authorized company. The employee app resolves a verified login link before reading payroll statements, tax forms and profile data for its company. The Solid Queue worker shares the Rails code and runs pay-stub posting, delivery and maintenance sweeps. The reviewer used Render logs for shadow evidence. The rollout lead separately verified the owner-side production baseline below. Per-service runtime connection checks and deployed revisions remain open.

## Production baseline

The rollout lead ran the owner-side read-only SQL. These results matched the expected shadow state.

| Check | Result |
| --- | --- |
| PostgreSQL and maintenance owner | PostgreSQL 16 or newer. Owner bypasses RLS. |
| Release migrations | 2 applied |
| Protected tables | 154 registered, 154 present, 0 enabled, 0 forced, 0 flag mismatches, 0 without a staged policy |
| Protected table ownership | 0 table owners that the runtime role is a member of |
| Kill switch | `bypass_enabled=false` |
| Login-link decision function | `SECURITY DEFINER`, stable, pinned search path, `row_security=off`, owner bypasses RLS, runtime can execute, 2 grantees, 0 unexpected ACL entries |
| Pay period states | 9 approved, 28 calculated, 5 draft |
| Active print generations | 0 |
| Demo early-access windows | 1 current, 0 retired |
| Staff web environment | `APP_PROCESS_ROLE` unset (effective `all`), `RLS_CONTEXT_GUARD_MODE=log`, `RLS_EXPECT_ENFORCED` unset |

The pay period counts are a baseline. Confirm the completed pay run and absence of active payroll operations with the payroll operator at cutover.

## Shadow-mode evidence

Queried the three authorized service streams individually with `render logs -r` and `--text`. The server rejected starts older than 30 days. The accepted interval was 2026-10-27 07:14:47 UTC through 2026-11-26 07:14:12 UTC. First- and last-entry probes found the following returned coverage. The oldest returned entry can reflect retention, service age or activity. [Render log retention](https://render.com/docs/logging#retention-period).

| Exact marker or coverage | Staff web | Solid Queue worker | Employee API |
| --- | ---: | ---: | ---: |
| First returned entry, UTC | Nov 19 10:14:11 | Nov 19 05:35:00 | Nov 25 08:06:24 |
| Last returned entry, UTC | Nov 26 07:13:19 | Nov 26 07:14:00 | Nov 26 07:14:00 |
| `rls_missing_context` | 0 | 0 | 0 |
| `rls_unclassified_sql` | 0 | 0 | 0 |
| `[RLS]` | 0 | 0 | 0 |
| `TenantScope` | 0 | 0 | 0 |
| `context guard` | 0 | 0 | 0 |
| `rls.context_violation` | 0 | 0 | 0 |
| `RLS context missing` | 8 DDL messages | 0 | 0 |
| `PG::InsufficientPrivilege` | 0 | 0 | 0 |
| `new row violates row-level security policy` | 0 | 0 | 0 |

The staff matches were INFO-level SQL definition output containing the exception string compiled into `app_current_company_id()`. All eight map to the policy installer definition. No runtime violation, controller action or job failure was present in the returned matches. The structured guard emits `rls_missing_context` and `rls_unclassified_sql` in `log`. In `raise`, it emits the in-process notification and raises `TenantScope::MissingContextError` before the structured warning, except during bypass. The notification name is searched as a cross-check and is not itself a production log event. Some supplemental phrase searches timed out on wide ranges. The counts above use successful queries, including results from capped shorter slices for exception phrases. [Guard source](../../api/app/services/rls_context_guard.rb#L16-L55), [database exception definition](../../api/db/rls_policies.sql#L1-L15), [shadow report task](../../api/lib/tasks/rls.rake#L80-L99).

Zero observed violations do not establish execution of rare year-end tasks or all current paths across a complete pay cycle. The release runner also sets its Rails logger to ERROR, hiding guard warnings from its own shadow executions. Obtain a full-cycle export or record a full observed cycle on the approved code with controlled exercises for rare paths. [Release runner logger](../../ops/payroll-release-day/release_day.rb#L61-L68).

## Code audit

### Findings addressed in the code PR

| Path | Failure and fix |
| --- | --- |
| Year-end FICA release runner, `ops/payroll-release-day/release_day.rb:94,107,137,142,161,187,192` | **Fixed locally in the code PR.** Before the fix, both preview and apply hit the unscoped cross-company inventory at line 94. Other unscoped reads include imported payroll inventory and latest source-review rows. The inventory touches `employees`, `payroll_items`, `pay_periods`, historical paychecks and source reviews. Rails `raise` rejects it even before PostgreSQL is enforced. Direct RLS queries also lack the required DB settings. The fix puts authorized before/after inventory in system scope and selected-company direct reads in their company scope. It preserves the repeatable-read snapshots, separates the scopes from the existing Rake entry points, and keeps the review and digest gates. The real runner passed preview and apply in the forced-RLS rehearsal. [Runner](../../ops/payroll-release-day/release_day.rb#L89-L194), [native inventory query](../../api/app/services/payroll_fica_legacy_recovery.rb#L97-L107), [imported inventory queries](../../api/app/services/imported_paycheck_fica_reconciliation.rb#L4-L8). |
| Early-access retirement, `api/app/services/employee_app_switch/enforcement.rb:126-129,151-173` | **Fixed locally in the code PR.** A company-scoped reader could retire a window and leave the next system sweep with nothing to audit. Company and support readers now leave retirement to the system sweep. An eligible system path locks the open windows and commits each retirement with its organization audit in the same transaction. Verified enforcement keeps the demo open while the sweep is pending. [Retirement path](../../api/app/services/employee_app_switch/enforcement.rb#L123-L174), [system sweep](../../api/app/services/employee_app_switch/demo_expiry.rb#L19-L32). |

### Safe in the reviewed entry points

| Path | Context and verdict |
| --- | --- |
| Staff and client reports and imports | **Safe.** Staff/client report and payroll import actions inherit company scope, including their preview, lock, apply and serialization paths. The bulk employee preview/apply endpoints use the same scope. The legacy SSN cache cleanup is cache-only. [Scope and rescue handling](../../api/app/controllers/concerns/company_rls_scoped.rb#L6-L31), [staff reports](../../api/app/controllers/api/v1/admin/reports_controller.rb#L6), [client reports](../../api/app/controllers/api/v1/client/reports_controller.rb#L6-L19), [payroll imports](../../api/app/controllers/api/v1/admin/payroll_imports_controller.rb#L7-L11), [bulk employee imports](../../api/app/controllers/api/v1/admin/employee_bulk_imports_controller.rb#L6-L17), [cache task](../../api/lib/tasks/bulk_import_ssn_cache.rake#L3-L8). |
| Organization reports and deferred exports | **Safe.** Inbox, client profitability and audit history declare a system reason and apply application authorization. Audit CSV opens an independent system scope per batch because the response body runs after action scope. Presenters reuse an existing scope, or open system mode for preloaded authorized subjects. [Inbox](../../api/app/controllers/api/v1/admin/client_inbox_controller.rb#L27), [profitability](../../api/app/controllers/api/v1/admin/client_profitability_controller.rb#L139), [audit history](../../api/app/controllers/api/v1/admin/audit_logs_controller.rb#L58), [audit stream](../../api/app/controllers/api/v1/admin/audit_logs_controller.rb#L154-L172), [presenter](../../api/app/services/audit_log_presenter.rb#L117-L134). |
| Year End, W-2GU and 1099 | **Safe.** Year End's grouped clients overview runs in system scope using accessible companies. The checklist, input revision, W-2GU aggregation, filing population, exports and 1099 reporting inherit the selected company scope. The e-file and W-2GU copy jobs scope by queued company. The wage-impact Rake entry point has its own system context. Services like the W-2GU aggregator depend on a scoped caller. [Year End controller](../../api/app/controllers/api/v1/admin/year_end_controller.rb#L9-L25), [overview](../../api/app/services/year_end/clients_overview.rb#L24-L26), [input revision](../../api/app/services/year_end/input_revision.rb#L13-L25), [W-2GU aggregation](../../api/app/services/w2_gu_aggregator.rb#L26-L49), [filing population](../../api/app/services/w2_gu_filing_population.rb#L6-L20), [efile job](../../api/app/jobs/year_end_efile_check_job.rb#L4-L12), [copy job](../../api/app/jobs/post_employee_w2_gu_copies_job.rb#L6-L17), [wage-impact task](../../api/lib/tasks/year_end_wage_impact.rake#L7-L13). |
| Employee link discovery, employee-facing data, View As | **Safe.** Discovery and claim use system scope with authorized login/link predicates. A verified link or support grant then selects company scope for data and staff audit work. The support token lookup is restricted to the signed-in actor and digest before a company is entered. Support requests enforce read-only. Check the independent `VIEW_AS_READY` and Clerk origin configuration before the guard change, since `raise` satisfies one of the activation prerequisites. [Employee lookup](../../api/app/controllers/api/v1/employee_portal/base_controller.rb#L77-L93), [account context](../../api/app/controllers/api/v1/employee_portal/account_controller.rb#L50-L56), [support grant](../../api/app/models/view_as_grant.rb#L17-L43), [support target resolution](../../api/app/controllers/concerns/view_as_enforcement.rb#L20-L59), [write fence](../../api/app/controllers/concerns/view_as_enforcement.rb#L98-L103). |
| Email-change and activation notice sweeps | **Safe.** The recurring entries use the normal Active Job entry point. Both jobs declare system scope for the single-record send and the no-argument scan. Post-commit callbacks enqueue scalar identifiers. The two senders read and update persisted rows inside the job scope and use their existing demo and delivery checks. [Schedule](../../api/config/recurring.yml#L48-L58), [email-change job](../../api/app/jobs/send_employee_email_change_notice_job.rb#L8-L20), [activation job](../../api/app/jobs/send_employee_activation_notice_job.rb#L7-L19), [email-change sender](../../api/app/services/employee_links/email_change.rb#L78-L151), [activation sender](../../api/app/services/employee_links/activation_notice_email.rb#L25-L129). |
| Other employee mail, document delivery and webhook | **Safe.** App delivery uses scoped services and jobs rather than Action Mailer model lookup. No application mailer subclass or `deliver_later` caller currently queries protected data. The tax-form dispatcher selects a company for a targeted run and system mode for the scheduled sweep. The provider webhook uses a global event inbox and a scoped notice reconciliation. [Mailer boundary](../../api/app/mailers/application_mailer.rb#L3-L6), [mail job](../../api/app/jobs/application_mail_delivery_job.rb#L3-L5), [dispatcher](../../api/app/jobs/dispatch_employee_tax_form_notices_job.rb#L21-L43), [reconciliation](../../api/app/services/employee_documents/notice_delivery_event.rb#L52-L94). |
| Other recurring sweeps | **Safe.** Pay-stub posting, link expiry, demo expiry, Clerk-revocation retry and practice expiry use system scope. Portal cleanup/notifications, effective compensation, reminders, AIRE acknowledgements/calendar, history bootstrap, check-print recovery and document-scan recovery also declare system scope. Solid Queue cleanup, recurring invoice/email dispatch and work-hours refresh use queue/global or exempt relations. [All schedules](../../api/config/recurring.yml#L12-L128), [stubs](../../api/app/jobs/post_employee_pay_stubs_job.rb#L4-L21), [link expiry](../../api/app/jobs/expire_employee_links_job.rb#L12), [demo expiry](../../api/app/jobs/close_expired_demo_early_access_job.rb#L6-L12), [Clerk retry](../../api/app/jobs/retry_employee_app_clerk_revocations_job.rb#L12), [portal cleanup](../../api/app/jobs/portal_upload_cleanup_job.rb#L4), [compensation](../../api/app/jobs/sync_effective_compensation_job.rb#L10), [AIRE dispatch](../../api/app/jobs/aire_payroll_acknowledgement_dispatch_job.rb#L4), [check-print recovery](../../api/app/jobs/check_print_generation_recovery_job.rb#L4), [document recovery](../../api/app/jobs/client_document_scan_recovery_job.rb#L6). |
| Remaining jobs and system scopes | **Safe.** Company jobs derive context from trusted scalar arguments. Record-ID jobs open system scope when standalone and preserve an existing company scope when inline. System jobs cover execution and handled retries/discards. System call sites cover authenticated identity/link resolution, scoped admin multi-company queries, audit writers, scheduled dispatch and recovery, operator tasks, demo setup, and restricted AIRE/Cable entry points. The system scope grants cross-company visibility, so those call sites rely on their existing actor and input constraints. No reviewed request path needed a broader scope. [Job boundary](../../api/app/jobs/application_job.rb#L3-L39), [scope nesting and restoration](../../api/app/services/tenant_scope.rb#L10-L45), [caller inventory](../RLS_CALLER_INVENTORY.md#http-controllers), [AIRE receiver](../../api/app/services/aire_payroll_events/receiver.rb), [Cable subscription](../../api/app/channels/client_portal_thread_channel.rb). |
| Rake, historical loaders and seed scripts | **Safe for supported production entry points.** The FICA Rake tasks themselves, QuickBooks/history imports, liability backfill, demo operations and applicable readiness checks already provide scope. The payroll-history detector selects a company. Terms publication and employee-mail previews use global or synthetic data. Owner tasks act through a separate direct connection; `rls:status` reads catalogs. Local fixture and staging seed scripts may deliberately issue unscoped protected queries in their supported isolated setup. Exclude them from production. Tenant writes in `db:seed` are development-only. [Rake wrapper](../../api/lib/rls_task.rb#L4-L9), [FICA tasks](../../api/lib/tasks/fica_legacy.rake#L6-L69), [history import](../../api/lib/tasks/quickbooks_history.rake#L6-L10), [demo tasks](../../api/lib/tasks/demo_seed.rake), [history detector](../../api/lib/tasks/payroll_history_review.rake#L5-L16), [readiness task](../../api/lib/tasks/production_readiness.rake#L6-L16), [staging-only script](../../api/script/staging_v2_seed.rb#L1-L12), [development seed guard](../../api/db/seeds.rb#L122). |

## Local rehearsal

- PostgreSQL 16.11 in a dedicated local cluster with synthetic data, separate from the machine's shared PostgreSQL. On the audited revision, 320 examples passed across company isolation, enforced end-to-end and contact requests, task and enforcement specs, production readiness, reports, demo switch, employee notices and View As. The total includes the two disposable diagnostic examples below. The first combined attempt collided with the local task rehearsal's cluster-wide fixture role. The clean rerun passed after the local fixture role was removed from the isolated cluster.
- Ran `rls:install`, `rls:enforce DRY_RUN=1`, the first ten-table batch and full `rls:enforce` with a direct owner connection. Observed shadow `0/154`, partial `10/154`, then enforced `154/154`, with no mixed flags. Set the kill switch, ran `rls:disable` and observed shadow `0/154`. Cleared the switch and confirmed it was off. The exercise used zero inter-batch delay and had no production lock traffic. All three read-only SQL checks below also executed successfully against the isolated cluster.
- Two initial diagnostic examples confirmed the release inventory failure and the retirement audit gap. The three regression examples in the code PR then failed on the baseline for the expected reasons. The affected suite passed 245 examples, and 146 retirement-related examples passed again after the lock-order adjustment.
- The code PR's separate PostgreSQL 16 rehearsal ran real preview and digest-locked apply with the restricted runtime role, the guard in `raise`, and all 154 policies forced. The two selected synthetic employers received proofs and the unselected employer received none. In another forced-RLS exercise, two concurrent retirement attempts produced one organization audit and an organization lock deferred retirement to a retry.
- The owner-side production baseline above is complete. The production runtime role checks, deployed versions, complete pay-cycle evidence, UI and provider checks remain open.

## Read-only production queries for the lead

Run privately from the exact deployed API revision. The reviewer did not connect to production. In the owner shell, `MIGRATION_DATABASE_URL` must already point to the direct production primary owner. Generate the table list locally from the repository to detect missing registered relations or policies. All evidence below is catalog data or aggregate counts.

```sh
cd api
protected_tables=$(ruby -r ./lib/rls_tables -e 'puts RlsTables::PROTECTED_TABLES.to_a.sort.join(",")')
psql -X "$MIGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 -v protected_tables="$protected_tables" <<'SQL'
BEGIN READ ONLY;
SET LOCAL statement_timeout = '10s';

SELECT current_setting('server_version_num')::int >= 160000 AS postgres_16_or_newer,
       r.rolsuper OR r.rolbypassrls AS maintenance_owner_bypasses
FROM pg_roles r WHERE r.rolname = current_user;

SELECT count(*) AS applied_release_migrations
FROM public.schema_migrations
WHERE version IN ('20261126070000', '20261126110000');

WITH expected AS (
  SELECT unnest(string_to_array(:'protected_tables', ',')) AS table_name
), actual AS (
  SELECT c.oid, c.relname, c.relrowsecurity, c.relforcerowsecurity, c.relowner
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
)
SELECT count(*) AS registered,
       count(a.oid) AS present,
       count(*) FILTER (WHERE a.relrowsecurity) AS enabled,
       count(*) FILTER (WHERE a.relforcerowsecurity) AS forced,
       count(*) FILTER (WHERE a.relrowsecurity <> a.relforcerowsecurity) AS mismatched_flags,
       count(*) FILTER (WHERE NOT EXISTS (
         SELECT 1 FROM pg_policy p WHERE p.polrelid = a.oid
       )) AS without_policy,
       count(*) FILTER (WHERE a.relowner IS NOT NULL
         AND pg_has_role('payroll_app', a.relowner, 'MEMBER')) AS runtime_member_of_table_owner
FROM expected e LEFT JOIN actual a ON a.relname = e.table_name;

SELECT bypass_enabled FROM rls_admin.rls_kill_switch WHERE singleton;

WITH fn AS (
  SELECT p.*, coalesce(p.proacl, acldefault('f', p.proowner)) AS acl
  FROM pg_proc p
  WHERE p.oid = to_regprocedure('public.payroll_employee_login_link_decision(bigint,bigint,bigint[])')
)
SELECT fn.prosecdef AS security_definer, fn.provolatile = 's' AS stable,
       coalesce('search_path=pg_catalog, pg_temp' = ANY (fn.proconfig), false) AS pinned_search_path,
       coalesce('row_security=off' = ANY (fn.proconfig), false) AS row_security_off,
       owner.rolsuper OR owner.rolbypassrls AS owner_bypasses,
       has_function_privilege('payroll_app', fn.oid, 'EXECUTE') AS runtime_can_execute,
       (SELECT count(DISTINCT a.grantee) FROM aclexplode(fn.acl) a
        WHERE a.privilege_type = 'EXECUTE') AS execute_grantees,
       EXISTS (SELECT 1 FROM aclexplode(fn.acl) a
               WHERE a.grantee NOT IN (fn.proowner, 'payroll_app'::regrole)
                  OR (a.is_grantable AND a.grantee <> fn.proowner)) AS unexpected_acl
FROM fn JOIN pg_roles owner ON owner.oid = fn.proowner;

SELECT status, count(*) FROM public.pay_periods
WHERE status IN ('draft', 'calculated', 'approved') GROUP BY status ORDER BY status;
SELECT count(*) AS active_print_generations
FROM public.check_print_generations WHERE status IN ('queued', 'processing');

SELECT count(*) FILTER (WHERE ended_at IS NULL AND retired_at IS NULL
                           AND expires_on >= (CURRENT_TIMESTAMP AT TIME ZONE 'Pacific/Guam')::date)
       AS current_demo_windows,
       count(*) FILTER (WHERE retired_at IS NOT NULL) AS retired_demo_windows
FROM public.employee_app_early_access_windows;
COMMIT;
SQL
```

Before enforcement, expect both release migrations, all registered tables present, zero enabled/forced/mismatched, a staged policy on each, no runtime membership of any protected table's owner, and a false switch. The function should have one result row and exactly two executor roles, with all five positive capability fields true, `runtime_can_execute` true, and `unexpected_acl` false. Check the current fixture window and live switches in the UI. Pay period status counts are a reconciliation aid. The operator must verify the last run and confirm no active work.

Run the following in the actual direct primary runtime connection for each service, with `RLS_DATABASE_URL` supplied through its secure environment. It should return all true. Record the respective service's `APP_PROCESS_ROLE`, `RLS_CONTEXT_GUARD_MODE`, and `RLS_EXPECT_ENFORCED` separately. Avoid printing the URL or environment.

```sh
psql -X "$RLS_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN READ ONLY;
SELECT current_user = 'payroll_app' AS restricted_login,
       NOT r.rolsuper AND NOT r.rolbypassrls AS no_global_rls_bypass,
       has_table_privilege(current_user, 'rls_admin.rls_kill_switch', 'SELECT') AS can_read_switch,
       NOT has_table_privilege(current_user, 'rls_admin.rls_kill_switch',
                               'INSERT,UPDATE,DELETE,TRUNCATE') AS cannot_write_switch
FROM pg_roles r WHERE r.rolname = current_user;
COMMIT;
SQL
```

Take queue baselines using the actual queue connection, which may be separate from the primary. Repeat the query at each verification checkpoint. Compare counts and job classes privately.

```sql
BEGIN READ ONLY;
SELECT count(*) AS recent_workers FROM solid_queue_processes
WHERE kind = 'Worker' AND last_heartbeat_at >= CURRENT_TIMESTAMP - INTERVAL '5 minutes';
SELECT count(*) AS failed_executions FROM solid_queue_failed_executions;
SELECT count(*) AS ready_executions FROM solid_queue_ready_executions;
SELECT count(*) AS due_scheduled_executions FROM solid_queue_scheduled_executions
WHERE scheduled_at <= CURRENT_TIMESTAMP;
COMMIT;
```

The catalog checks confirm presence and flags. The owner dry run in the runbook compares exact policy definitions against the approved code and verifies the promoted child column contract.
