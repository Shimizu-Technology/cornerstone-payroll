# Deploy effective-dated compensation on Render

Ship #525, #526 and #527 together. Record the final merged SHA and coordinate one maintenance window with payroll operations. Keep auto-deploy off for the Render API and worker. Hold the frontend publication for the same window. The Render API web service is `srv-d74hd8v5r7bs73ctg8a0`. The background worker is `srv-d75lj8muk2gs73dbg5og`.

## 1. Enter maintenance and pause workers

- Block staff, client and integration writes at the API. Cover automation, direct API clients, and operator consoles as well as the frontend. Keep this block in place through step 6.
- Drain in-flight jobs, then stop worker job consumption and recurring scheduling. Pause every other process that can write payroll or employee setup, including one-off jobs and any web-side queue. Specifically prevent `SyncEffectiveCompensationJob` from running or being picked up during this window. Check running and queued jobs before continuing.
- Capture employee and wage-rate row counts, the paycheck totals from step 6, and representative existing stubs for AIRE, MoSa’s, Spike and manual payroll. Record the baseline after writes have drained. Retain it in the release record with the SHA and time.

## 2. Verify that legacy writers are drained

Verify maintenance blocks writes from an authenticated staff and client entry point. Confirm all worker consumers and schedulers are paused, all old write-capable one-offs are stopped, and in-flight requests have drained on every old web instance. A quiet database snapshot alone cannot establish that an old writer is fenced off.

Run this read-only check using the direct database connection with visibility into app sessions. Investigate any active statement, open transaction, or write lock held by a legacy web or worker connection using the Render process inventory. Continue only when the operator can account for every such session and none can write.

```sql
SELECT a.pid, a.application_name, a.client_addr, a.state, a.xact_start,
       c.relname, l.mode, l.granted
FROM pg_stat_activity a
LEFT JOIN pg_locks l ON l.pid = a.pid AND l.locktype = 'relation'
  AND l.relation IN ('employees'::regclass, 'employee_wage_rates'::regclass)
LEFT JOIN pg_class c ON c.oid = l.relation
WHERE a.datname = current_database()
  AND a.pid <> pg_backend_pid()
  AND (a.state <> 'idle' OR a.xact_start IS NOT NULL OR l.mode = 'RowExclusiveLock')
ORDER BY a.pid, c.relname;
```

## 3. Migrate in the web pre-deploy step

After the drain is verified, manually trigger the exact merged SHA on the Render web service. Its configured `bin/rails db:safe_prepare` pre-deploy command uses the direct migration connection and runs migration `20261122120000` before new web instances start. This pre-deploy step is the migration owner. If it fails, keep maintenance and the worker pause in place and investigate before retrying. The migration backfills compensation history and takes DDL locks with a five-second lock timeout.

Confirm pre-deploy succeeded and the following query returns the version before treating the web revision as deployed.

```sql
SELECT version FROM schema_migrations WHERE version = '20261122120000';
```

## 4. Deploy the full stack behind maintenance

Verify the new API is healthy and running the selected SHA. Publish the matching frontend build while access is blocked. Prepare the worker on the same SHA with job consumption and scheduling still disabled. If the platform pause prevents deploying the worker, keep it suspended and deploy the selected revision with consumption blocked before resuming jobs in step 6. Verify no old revision can resume.

## 5. Reconcile drift and prove the rerun is empty

From the new API release, run `bin/rails compensation:reconcile_rollout`. Save its ID and count output. It records legacy cache drift after the backfill, preserving approved and committed period dates. Drift whose next allowed date is in the future is recorded for that date, so the cache still reflects today's protected basis. Work commits one employee at a time. If the task reports a failure, resolve it and rerun while writes remain blocked.

After a successful run, run the same command again. Require the exact summary `employee_count=0 wage_rate_count=0` and no failure. If the window crosses midnight Guam time, refresh the dated cache with the new release's `bin/rails compensation:sync_effective` after reconciliation succeeds, then rerun the SQL against the new Guam date.

## 6. Verify, then reopen

Run the following read-only checks from one snapshot. All four exception counts must be zero. Reserved inactive rows without a version today are expected for future-only or cancelled wage definitions. The checks still require versions for every legacy, non-reserved wage row.

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;

WITH clock AS (
  SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'Pacific/Guam')::date AS today
),
employee_check AS (
  SELECT e.id,
         count(v.id) AS covering_count,
         bool_or(ROW(e.pay_rate, e.employment_type, e.salary_type,
                     e.pay_frequency, e.contractor_pay_type)
                 IS DISTINCT FROM
                 ROW(v.pay_rate, v.employment_type, v.salary_type,
                     v.pay_frequency, v.contractor_pay_type))
           FILTER (WHERE v.id IS NOT NULL) AS cache_differs
  FROM employees e CROSS JOIN clock
  LEFT JOIN employee_compensation_changes v
    ON v.employee_id = e.id AND v.company_id = e.company_id
   AND v.effective_on <= clock.today
   AND (v.ends_on IS NULL OR v.ends_on >= clock.today)
  GROUP BY e.id
),
wage_check AS (
  SELECT w.id,
         starts_with(w.label, '__compensation_cache__') AS reserved,
         w.active, w.is_primary,
         count(v.id) AS version_count,
         count(v.id) FILTER (WHERE v.effective_on <= clock.today
            AND (v.ends_on IS NULL OR v.ends_on >= clock.today)) AS covering_count,
         bool_or(ROW(w.label, w.rate, w.is_primary, w.active)
                 IS DISTINCT FROM ROW(v.label, v.rate, v.is_primary, v.active))
           FILTER (WHERE v.effective_on <= clock.today
             AND (v.ends_on IS NULL OR v.ends_on >= clock.today)) AS cache_differs
  FROM employee_wage_rates w CROSS JOIN clock
  LEFT JOIN employee_wage_rate_versions v
    ON v.employee_wage_rate_id = w.id AND v.employee_id = w.employee_id
  GROUP BY w.id
)
SELECT (SELECT count(*) FROM employee_check WHERE covering_count <> 1) AS employee_version_exceptions,
       (SELECT count(*) FROM employee_check WHERE cache_differs) AS employee_cache_exceptions,
       (SELECT count(*) FROM wage_check WHERE NOT reserved AND version_count = 0) AS legacy_wages_without_history,
       (SELECT count(*) FROM wage_check WHERE covering_count > 1 OR cache_differs
          OR (covering_count = 0 AND (NOT reserved OR active OR is_primary))) AS wage_cache_exceptions;

SELECT (SELECT count(*) FROM employees) AS employees,
       (SELECT count(*) FROM employee_wage_rates) AS wage_rates;

-- Also run before migration for an exact comparison by company and period.
SELECT p.company_id, p.id AS pay_period_id, p.status, count(i.id) AS paychecks,
       coalesce(sum(i.gross_pay), 0) AS gross_pay,
       coalesce(sum(i.total_deductions), 0) AS total_deductions,
       coalesce(sum(i.net_pay), 0) AS net_pay
FROM pay_periods p LEFT JOIN payroll_items i ON i.pay_period_id = p.id
WHERE p.status IN ('draft', 'calculated', 'approved', 'committed')
GROUP BY p.company_id, p.id, p.status
ORDER BY p.company_id, p.id;

COMMIT;
```

Compare row counts, paycheck totals and representative stubs with the pre-deploy evidence without recalculating payroll. Hold maintenance on any unexplained difference, migration error, nonzero rerun, or unverified release SHA.

When the checks pass, reopen staff, client and integration traffic and resume the new worker and recurring jobs. Verify the activation job is scheduled for 00:05 Guam time and that only the new SHA is consuming jobs. Refresh in-flight promotion and go-live previews before applying them.

Follow-up after rollout: verify a database write-session trigger through the production-like PgBouncer transaction pooler and `db:integrity` before proposing enforcement in a separate PR.
