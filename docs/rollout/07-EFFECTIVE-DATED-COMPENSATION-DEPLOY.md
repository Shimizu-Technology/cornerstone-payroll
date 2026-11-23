# Deploy effective-dated compensation on Render

Ship #525, #526 and #527 together. Record the final merged SHA and coordinate one maintenance window with payroll operations. Keep auto-deploy off for the Render API and worker. Hold the frontend publication for the same window. The Render API web service is `srv-d74hd8v5r7bs73ctg8a0`. The background worker is `srv-d75lj8muk2gs73dbg5og`.

Merge and deploy the write-maintenance switch PR before starting this rollout. Follow the [write-maintenance runbook](../runbooks/WRITE_MAINTENANCE.md).

## 1. Enable write maintenance on the web service

Set `WRITE_MAINTENANCE=true` on the Render web service and restart it. Verify that an authenticated POST to an `/api/*` endpoint returns HTTP 503 with `code: "write_maintenance"`. Confirm that GET requests and `/up` still work. Keep the switch enabled until step 8.

## 2. Suspend the worker and verify that legacy writers are drained

Drain in-flight jobs, then suspend the Render worker to stop job consumption and recurring scheduling. Pause all other payroll and employee setup writers, including one-off jobs and any web-side queue. Confirm that `SyncEffectiveCompensationJob` cannot run and that in-flight requests have drained on every old web instance.

After writes have drained, capture employee and wage-rate row counts, the paycheck totals from step 6, and representative existing stubs for AIRE, MoSa’s, Spike and manual payroll. Retain the baseline in the release record with the SHA and time.

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

After verifying the drain, manually deploy the exact merged SHA on the Render web service with `WRITE_MAINTENANCE=true` still set. Its configured `bin/rails db:safe_prepare` pre-deploy command uses the direct migration connection and runs migration `20261122120000` before new web instances start. This pre-deploy step is the migration owner. If it fails, keep maintenance and the worker pause in place and investigate before retrying. The migration backfills compensation history and takes DDL locks with a five-second lock timeout.

On the production clone, confirm that payroll history review migration `20261123130000` is already applied and compensation migration `20261122120000` is pending before the run. Rails tracks each migration version, so the newer applied migration does not prevent `db:safe_prepare` from running the older pending migration. After pre-deploy, confirm the query returns both versions before treating the web revision as deployed.

```sql
SELECT version FROM schema_migrations
WHERE version IN ('20261122120000', '20261123130000')
ORDER BY version;
```

## 4. Verify the web release and reconcile drift

Verify the web service is healthy and running the selected SHA. Repeat the POST check from step 1.

From the new API release, run `bin/rails compensation:reconcile_rollout`. Save its ID and count output. It records legacy cache drift after the backfill, preserving approved and committed period dates. Drift whose next allowed date is in the future is recorded for that date, so the cache still reflects today's protected basis. Work commits one employee at a time. If the task reports a failure, resolve it and rerun while writes remain blocked.

## 5. Verify that reconciliation is idempotent

After a successful run, run the same command again. Require the exact summary `employee_count=0 wage_rate_count=0` and no failure. If the window crosses midnight Guam time, refresh the dated cache with the new release's `bin/rails compensation:sync_effective` after reconciliation succeeds, then rerun the SQL against the new Guam date.

## 6. Verify compensation and paycheck totals

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

## 7. Deploy and resume the worker

After the step 6 checks pass, deploy the worker on the same SHA and resume job consumption and recurring scheduling. Verify that only the new SHA is consuming jobs and that the activation job is scheduled for 00:05 Guam time.

## 8. Reopen API writes

Unset `WRITE_MAINTENANCE` and restart the web service. Verify that authenticated writes are available again. Refresh in-flight promotion and go-live previews before applying them.

## 9. Deploy Netlify

Deploy the matching frontend build to Netlify after API writes are available.

Follow-up after rollout: verify a database write-session trigger through the production-like PgBouncer transaction pooler and `db:integrity` before proposing enforcement in a separate PR.
