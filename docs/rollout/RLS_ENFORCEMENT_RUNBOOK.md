# Postgres RLS enforcement runbook

**Current decision: hold.** Resolve the code and evidence gates in the [readiness report](RLS_ENFORCEMENT_READINESS.md) before scheduling the production change. The rollout lead executes this procedure. The payroll operator confirms the end of the run and owns the payroll smoke test. Use the private rollout record for timestamps, deployed revisions, service settings, fixture references, check results and the go or rollback decision.

## Before the window

1. Close the code and evidence gates. Deploy the approved compatible revision to all three Rails services before the window, including the [promoted-child contract migration](../../api/db/migrate/20261126070000_contract_payroll_child_companies.rb) and the [employee email-change notice migration](../../api/db/migrate/20261126110000_create_employee_email_change_notices.rb). Use the staff web service's normal owner-backed migration path (`bin/rails db:safe_prepare`) for schema changes. The employee API does not migrate. Record the deployed revision of each service. Schedule this separately from Clerk or other cutovers.
2. Obtain a clean shadow report for at least one complete pay cycle with the reviewed code and relevant paths exercised. Compare actual cycle boundaries to log coverage. Include guard failures on the employee API, where `raise` normally emits exceptions rather than structured warning lines. Keep exports private. Feed application JSON messages to `bundle exec rails rls:shadow_report < exported.log` from `api/` and require `[]`. Inspect the exception and database markers listed under monitoring as well.
3. Schedule the flip right after a completed pay run at low traffic. Confirm the run is committed and all payment, print and reconciliation work intended for the window is complete. Pause starts, edits, calculations, imports, approvals, finalizations and print work for the duration. Inspect the queue for in-flight work. Leave the queue worker available for the non-payroll smoke checks. Open draft rows alone do not establish that payroll is in progress. Get explicit confirmation from the payroll operator.
4. Verify a recent restorable backup and create a named Neon branch or snapshot from the production recovery point after the pay run. Record its UTC recovery point and retention privately. Keep it isolated from live services and outbound integrations. Confirm the owner can connect to the direct endpoint and has a separate owner session ready for emergency rollback. Rehearse the rollback on a contained copy. Use the catalog checks in the readiness report against production before the change. [Neon branching and recovery](https://neon.com/storage).
5. Confirm primary direct connection headroom for overlapping Render instances, the worker and owner sessions. Confirm the staff web and worker use `log`, the employee API uses `raise`, and all three primary connections use the same production primary through the direct `payroll_app` role. Keep queue, cache and cable URLs, worker start settings, and employee API role and pool cap as deployed.
6. Record all pre-flip open early-access windows privately. Confirm a window covers the active demo through the cutover, the demo flags and their switch activations are on, and an existing demo employee can sign in on its own employee address and open a known statement. Record the expected counts and amounts from approved fixtures for the smoke tests. Employee access under the waiver is expected to pause temporarily during partial enforcement. Confirm whether any real company has employee access and have its switch admin available for emergency shutdown. Confirm whether View As is approved on staff web, since the move to `raise` can activate it if the other prerequisites are already set.
7. From `api/` in each deployed service environment, run the checks below. `production:readiness` includes live cache, storage and provider probes. Record its output privately. The owner **dry run** also creates temporary comparison objects. Use the read-only SQL from the report for catalog-only verification.

   ```sh
   bundle exec rails rls:status
   bundle exec rails production:readiness
   bundle exec rails payroll_child_companies:verify
   ```

   Expect the direct runtime to report `payroll_app` with `rolsuper=false` and `rolbypassrls=false`, kill switch `false`, `shadow`, `0/154` tables enforced for the audited revision, an empty `enabled_xor_forced` list and a policy on every registered table. Use the current registry count if the approved revision has changed. The child verifier must report `nulls=0 parent_fk=valid` for all 26 promoted tables. Runtime role, selected phase and restricted login-link decision must pass, along with the employee API's four `employee_web:` checks. Verify the restricted function's executor and owner against the catalog and the approved revision. Reconcile any readiness failure before the window.

## Change order

Render's **Environment → Edit → Save and deploy** applies the new values to the existing build. Use the service's own variables for the sequence below. Verify the same approved commit is live after each deploy. [Render environment changes](https://render.com/docs/configure-environment-variables).

| Render service | Before | Before policy DDL | After full policy verification |
| --- | --- | --- | --- |
| Staff web | `APP_PROCESS_ROLE` unset (effective `all`), guard `log`, expectation unset | Set `RLS_CONTEXT_GUARD_MODE=raise`. Leave the process role and expectation as they were. | Set `RLS_EXPECT_ENFORCED=true`. |
| Solid Queue worker | Effective `all`, guard `log`, expectation unset | Set `RLS_CONTEXT_GUARD_MODE=raise`. Keep its existing process role value and expectation. | Set `RLS_EXPECT_ENFORCED=true`. |
| Employee API | `APP_PROCESS_ROLE=employee_web`, guard `raise`, expectation unset | No deploy is required for this step. | Set `RLS_EXPECT_ENFORCED=true`. Keep `raise` and `employee_web`. |

Leave `RLS_DATABASE_URL` on all three services. Use `MIGRATION_DATABASE_URL` only in the secured owner command environment and the existing migration path. Keep `RLS_EXPECT_ENFORCED` unset until the full database change passes. It selects the readiness assertion. The guard mode controls Rails behavior, and the database DDL controls PostgreSQL behavior.

1. **Enable the raising guard while PostgreSQL is still in shadow.** Apply the worker change first, verify its heartbeat and a normal recurring execution, then apply the staff web change. Confirm `rls:status` reports `raise` and `shadow` on all three. Keep staff/worker route roles as configured. An unset `APP_PROCESS_ROLE` here can produce the existing advisory on those services. Smoke test the three surfaces and check logs for at least 15 minutes, including the 10- and 15-minute notice sweeps. Any new guard failure or missing result is a stop. Restore `log` on worker and staff web if this step fails.
2. **Preview the table batches.** In a secured shell from the deployed `api/` revision, with production config and the direct owner `MIGRATION_DATABASE_URL` already supplied, run:

   ```sh
   RAILS_ENV=production RLS_CONTEXT_GUARD_MODE=off bundle exec rails rls:enforce DRY_RUN=1
   ```

   It must list all pending protected tables. The owner task checks the kill switch, policy definitions, role and function privileges and child-column contract. Stop on any preflight error. If staged definitions drifted, reconcile the code and policies in an approved pre-window change, then rerun preflight. The registry supplies the table list and puts core payroll and audit tables last.
3. **Apply only the first batch.** Copy the comma-separated tables printed after `Batch 1:` into the shell variable.

   ```sh
   read -r RLS_PILOT_TABLES
   RAILS_ENV=production RLS_CONTEXT_GUARD_MODE=off \
     bundle exec rails rls:enforce "TABLES=$RLS_PILOT_TABLES"
   ```

   For each selected table the task commits `ALTER TABLE public.<table> ENABLE ROW LEVEL SECURITY` and `ALTER TABLE public.<table> FORCE ROW LEVEL SECURITY` together. It uses a three-second lock timeout with three attempts. A successful pilot prints `Selected tables are enabled and forced`. Check `rls:status` for `partial`, the exact pilot count with no mismatched flags, and kill switch `false`. Repeat the smoke tests for at least five minutes. The demo employee app should be gated after its cache expires. Record that expected pause.
4. **Enforce the remaining tables.**

   ```sh
   RAILS_ENV=production RLS_CONTEXT_GUARD_MODE=off bundle exec rails rls:enforce
   ```

   The task skips tables already enforced, commits per table, and pauses five seconds between batches of ten by default. It stops before the next table if the database kill switch changes. A lock or other failure can leave tables enforced. Inspect `rls:status` before choosing whether to resume the same command or roll back. Require `all_enforced: true`, `All protected tables are enabled and forced`, and a fresh status of `enforced`, all registered tables enabled and forced, the mismatch list empty, and the kill switch off.
5. **Retire the early-access windows.** Immediately after full enforcement is verified, run the job synchronously from `api/` in the deployed worker's runtime environment with the guard in `raise`.

   ```sh
   RAILS_ENV=production bundle exec rails runner 'CloseExpiredDemoEarlyAccessJob.perform_now'
   ```

   Check the stored `retired_at` and matching organization audit for every pre-flip open window. From the owner SQL session, pass the privately recorded window IDs as the `psql` variable `pre_flip_window_ids` using PostgreSQL array syntax. The query returns only counts.

   ```sql
   BEGIN READ ONLY;
   SELECT count(*) AS recorded_windows,
          count(*) FILTER (WHERE w.retired_at IS NOT NULL) AS retired_windows,
          count(*) FILTER (WHERE audit.rows = 1) AS windows_with_one_audit
   FROM public.employee_app_early_access_windows w
   CROSS JOIN LATERAL (
     SELECT count(*) AS rows
     FROM public.audit_logs a
     WHERE a.action = 'employee_app_early_access#retired'
       AND a.record_type = 'EmployeeAppEarlyAccessWindow'
       AND a.record_id = w.id
       AND a.organization_id = w.organization_id
       AND a.company_id IS NULL
   ) audit
   WHERE w.id = ANY (:'pre_flip_window_ids'::bigint[]);
   COMMIT;
   ```

   All three counts must equal the pre-flip cohort size. If a busy organization or window was skipped, resolve the lock, rerun the job, and repeat the query before continuing.
6. **Apply the readiness expectation.** Set `RLS_EXPECT_ENFORCED=true` and use **Save and deploy** on the employee API first, worker second, staff web third. After each deploy, verify health, revision, `rls:status` and `bundle exec rails production:readiness` in that service's environment. Require PASS for runtime role and kill-switch privileges, selected policy phase, restricted login-link function, and kill switch off. Also require all `employee_web:` checks on the employee API and a worker heartbeat less than five minutes old. Confirm the unauthenticated employee API `/health/dependencies` reports `ok` and the staff switch screen reports that the employee service and database checks pass. Treat service config, the health endpoint and DB status as separate observations.
7. Repeat full smoke tests and record the outcome. Reopen payroll changes only after the required checks pass and the payroll operator agrees.

## Smoke tests

Use authorized synthetic or designated test records. Execute the steps in the application under the listed roles and compare with the pre-window baseline. Keep downloads and test account identifiers in the private evidence location. Exercise real dispatch and write flows on a contained rehearsal with controlled delivery. In production use approved fixtures and avoid any test that would send a real message, file with an agency, or move money.

| Surface | What to do and expect |
| --- | --- |
| Staff web | Sign in, select the test company, open **Employees**, a profile, and **Pay Periods**. Open the just-completed run and compare payroll-item count, totals, and a known report or stub to baseline. In a test run, save a permitted draft edit, reload to verify persistence, and restore the fixture. As assigned-only staff, a separately authorized negative fixture from another company returns 404 or access denied. |
| Reports and imports | In the test company, open a payroll register and **Year End**, select the tax year, open the checklist, W-2GU preview and an authorized download. Compare counts and totals. Open a payroll import preview with a synthetic file and cancel. Run the corrected release-runner preview/digest/apply replay on the contained copy before production, then record its result with the window evidence. |
| Client portal | Sign in as a client manager. Open **Documents**, **Messages** and **Payroll**. Verify a known document download, a thread, and a finalized run and its totals. In a test workspace, stage an approved test upload, reload to verify its expected scan state and remove the fixture through the normal workflow. As a restricted client user, confirm the permissions and one cross-company refusal. |
| Employee API and app | Use the approved demo login on the proper employee site. Verify sign-in, employer selection if applicable, the pay-stub list and PDF, W-2GU list and an available PDF, and **Profile**. Under full enforcement, verify a same-person email confirmation saves and the other-company login case is refused using approved fixtures/contained rehearsal. An employee sees only their own documents. |
| Live demo | In shadow with `raise`, the demo still opens under its waiver. In the pilot's `partial` phase, the direct demo data request returns 404 and the link is absent from the link chooser after cache expiry. After full enforcement, the same active login opens and known documents match. Check the switch screen for the retired window and unchanged active flags. Exercise the demo client and staff views too. |
| View As | If already approved and enabled, use a permitted support admin and step up to open a designated client and demo employee view. The banner and selected company match, writes are refused, and ending the session returns to the staff identity. If disabled, verify it stays unavailable and leave its independent rollout settings in place. |
| Worker and integrations | Confirm recurring sweeps finish, especially both employee notice sweeps, pay-stub posting and demo expiry. Check heartbeat, failed-execution delta and due backlog. In a contained rehearsal, confirm a due notice is handled once and a retry reuses the same delivery key. Verify an authorized AIRE worker statement and a synthetic event flow if the integration is active. |

## Demo windows

Verified enforcement replaces the waiver. An eligible system read or the expiry sweep retires open windows permanently. Company-scoped and support reads leave retirement to the system sweep and can serve the demo as soon as enforcement is verified. A demo read can reuse a cached phase for up to five seconds per process. The partial phase and an active DB bypass close employee access under the demo gate. A still-in-effect window preserves the stored switches through the normal partial-to-full transition. On success, its existing activations and employee links continue to work without a waiver. Check the durable `retired_at` state and the matching organization audit after the first post-flip sweep. The fix commits retirement and its organization audit together. Confirm the fix revision is live before the window. [Retirement audit finding](RLS_ENFORCEMENT_READINESS.md#findings-addressed-in-the-code-pr).

## Monitor for 24–48 hours

- Check all three service streams at 15 minutes, one hour, 24 hours and 48 hours, and after the next daily jobs. Search `rls_missing_context`, `rls_unclassified_sql`, `TenantScope::MissingContextError`, `TenantScope::ConflictingContextError`, `PG::InsufficientPrivilege`, SQLSTATE `42501`, `RLS context missing` and `new row violates row-level security policy`. Treat a function-definition log line as DDL evidence. Correlate runtime errors by request or job in the private incident record.
- Compare staff and employee API 5xx rates, DB connection errors and saturation, lock waits, worker heartbeat, failed and scheduled executions, and pending email, cleanup and posting backlogs with the baseline. Open the known test lists again because an incorrect tenant can return a successful response with no records.
- Roll back on broken payroll, unexpected access, missing data for known fixtures, repeated guard errors, or stalled critical jobs. Keep the first normal payroll under enforcement as a separate employee-app go-live gate. [Employee go-live G4](M4_GO_LIVE_RUNBOOK.md).

## Roll back in minutes

If only the Rails guard was changed and `rls:status` still reports `shadow` with the switch off, restore `log` on staff web and worker using **Save and deploy**. Leave the employee API at `raise`. Verify the recovered surface and stop the rollout.

If any table has flipped, the lead and switch admin coordinate the following steps:

1. Keep payroll paused. Disable employee-app access for every enabled real company before bypass, as required by G4. If the switch UI is unavailable and real access is enabled or unknown, suspend the employee API in Render. On staff web set `APP_PROCESS_ROLE=payroll_web` and use **Save and deploy** to unmount the employee resource routes. Verify the dedicated API is unavailable and staff web rejects employee resource requests before bypass. Once access flags are verified off, restore the recorded staff web role on its next rollback deployment and resume the dedicated employee API with its restricted settings. Demo access closes under bypass after the cache delay. Use the emergency switch if the lead needs demo access closed immediately.
2. In the prepared direct owner `psql` session, run the following. Require `UPDATE 1` and `t`. The app picks up the change for new scopes within about five seconds per process. In-flight scopes keep their original settings. Readiness's kill-switch check fails while bypass is active. This is the immediate availability recovery while table locks are cleared.

   ```sql
   UPDATE rls_admin.rls_kill_switch
   SET bypass_enabled = true, updated_at = CURRENT_TIMESTAMP,
       reason = 'RLS rollout rollback'
   WHERE singleton;
   SELECT bypass_enabled FROM rls_admin.rls_kill_switch WHERE singleton;
   ```

3. From the same approved revision with the direct owner URL, disable RLS. The task waits up to 60 seconds for an active enforcement command, then disables each active registered table with `NO FORCE` and `DISABLE` in one transaction per table. If it reports remaining locks, confirm the bypass is still on and rerun after resolving those locks. Keep the schema migrations and staged policies in place.

   ```sh
   RAILS_ENV=production RLS_CONTEXT_GUARD_MODE=off bundle exec rails rls:disable LOCK_WAIT=60
   ```

4. Confirm fresh `rls:status` reports shadow, zero enforced and no mismatched flags. Remove `RLS_EXPECT_ENFORCED` from all three and restore `log` on staff web and worker. Apply changes by **Save and deploy** in worker, staff web, employee API order, verifying health after each. Keep the employee API at `raise` with its restricted role. With reverted processes healthy and all enforcement flags confirmed off, clear the bypass as owner. Require `UPDATE 1` and `f`.

   ```sql
   UPDATE rls_admin.rls_kill_switch
   SET bypass_enabled = false, updated_at = CURRENT_TIMESTAMP,
       reason = 'Shadow mode verified after rollback'
   WHERE singleton;
   SELECT bypass_enabled FROM rls_admin.rls_kill_switch WHERE singleton;
   ```

5. Run shadow readiness on all three, repeat staff/client/worker smoke tests, and reconcile affected writes and jobs before removing the payroll pause. Real employee access stays off pending restored enforcement. If rollback happens before the first sweep or system read retires a window, its still-valid waiver can apply again once shadow mode is restored and the bypass is cleared. If the old window was retired, the expiry sweep can close the demo's stored flags and revoke their activations. Let that reconcile, then have a super admin create a fresh approved window and the switch admin restore the required flags through the UI. Verify the same demo login and document access. Use the backup or Neon recovery branch only for a separate, explicitly authorized data recovery.
