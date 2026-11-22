# Payroll write maintenance

Use this window for migrations or reconciliation that require payroll changes to pause while staff retain access to existing data. Deploy the switch to the web service before the first release that needs it. It is off by default.

## Run a window on Render

1. **Turn on the switch.** On [the payroll web service](https://dashboard.render.com/web/srv-d74hd8v5r7bs73ctg8a0), open **Environment** and set `WRITE_MAINTENANCE=true` (lowercase). Optionally set `WRITE_MAINTENANCE_MESSAGE` to a short public message. Select **Save and deploy** to apply the environment change to the existing build. Render's **Save only** stages the values for a future deploy, and **Restart service** reuses the live deploy's configuration. Wait for the maintenance-enabled deploy to go live and the previous instance to drain. Run the probes below before starting the migration.
2. **Suspend the worker.** Suspend [the payroll Solid Queue worker](https://dashboard.render.com/worker/srv-d75lj8muk2gs73dbg5og). Confirm it is suspended and any in-flight jobs have exited. Confirm the web service uses `USE_SOLID_QUEUE=true` (the app default) and `SOLID_QUEUE_IN_PUMA=false` so it cannot run queued jobs itself. Account for any other operator or scheduled processes that write to the same tables before proceeding.
3. **Deploy and migrate.** Keep `WRITE_MAINTENANCE=true` on the web service. Deploy the intended commit and let its pre-deploy `db:safe_prepare` finish. Wait until the intended revision is live, then rerun the probes. Both the old and new web revisions need the switch enabled throughout this deploy.
4. **Run the release tasks and checks.** Run the planned reconciliation and integrity checks with the worker still suspended. Keep maintenance enabled if any check fails or the release needs recovery. If deploying a recovery revision, verify that it includes the switch and runs with the flag on.
5. **Turn off the switch.** Remove `WRITE_MAINTENANCE` or set it to `false`, remove any custom message, and select **Save and deploy** again. Wait for the new instance, check health, then verify the unauthenticated POST returns its normal `401` again. Do a release-appropriate authenticated write smoke check.
6. **Resume the worker.** Bring it back on the release-compatible revision. Confirm queued work drains and recurring dispatchers are healthy. Check pending and failed AIRE deliveries and any webhook or scheduled work due during the window. Replay unreceived events with their original idempotency keys when the sender supports replay. Check time-based schedules for missed slots because runs can be missed while the scheduler is suspended.

See [Render environment settings](https://render.com/docs/configure-environment-variables#in-the-render-dashboard) and [Render restarts](https://render.com/docs/deploys#restarting-a-service).

### Verify without changing payroll data

Run without credentials. The POST intentionally omits required data.

```sh
base=https://cornerstone-payroll-api.onrender.com
curl -i "$base/up"
curl -i "$base/health/dependencies"
curl -i -X POST -H 'Content-Type: application/json' --data '{}' "$base/api/v1/admin/departments"
```

During the window, `/up` should return `200`, dependency health should return its usual status, and the POST must return `503` with `Retry-After: 60` and `"code":"write_maintenance"`. After reopening, expect the unauthenticated POST to return `401`.

## Scope and retry behavior

- The middleware rejects all methods except GET, HEAD, and OPTIONS under `/api/` and the Rails Active Storage route prefix. This covers all roles, finance, multipart uploads, and both AIRE event webhook URLs. Read-oriented actions implemented as POST, such as some exports and previews, are also paused.
- Reads and health checks follow their usual paths. Those paths can still write operational metadata such as sign-in activity, access logs, or generated document previews. Direct database sessions, Rails tasks, and requests to an external object store with previously issued upload URLs are outside the HTTP switch.
- A webhook receives `503` before any event is accepted. AIRE retains the event in its outbox and retries on its own schedule (exponential backoff capped at one hour). The interactive AIRE cutoff-change request reports temporary unavailability and needs a manual retry. Confirm other webhook senders' retry or replay behavior when planning a window. [AIRE outbox](https://github.com/Shimizu-Technology/aire-services/blob/2d23f9a51fb5d31ad9a1315683d6dfb38e0c280b/backend/app/services/payroll/outbox_dispatcher.rb) · [AIRE retry schedule](https://github.com/Shimizu-Technology/aire-services/blob/2d23f9a51fb5d31ad9a1315683d6dfb38e0c280b/backend/app/services/payroll/retry_schedule.rb) · [AIRE cutoff change](https://github.com/Shimizu-Technology/aire-services/blob/2d23f9a51fb5d31ad9a1315683d6dfb38e0c280b/backend/app/services/payroll/cutoff_change_client.rb)
- The switch reads the process environment on each request. This keeps write rejection independent of database availability or schema changes during a migration. Render applies environment changes by replacing the web process.
- Suspending the worker stops both the scheduler and queue consumers at the process level. Existing queued jobs stay in Solid Queue and run when the worker resumes. This also covers jobs outside `ApplicationJob` and avoids re-enqueue loops.
