# Payroll write maintenance

Use this window for migrations or reconciliation that require payroll changes to pause while staff retain access to existing data. Deploy the switch to the web service before the first release that needs it. It is off by default.

Before the first window, deploy both the switch-capable API build and the corresponding frontend bundle to Netlify. Verify Netlify is serving that bundle and ask operators to refresh open payroll tabs. Older bundles lack the maintenance notice and realtime retry delay.

## Run a window on Render

1. **Turn on the switch.** On [the payroll web service](https://dashboard.render.com/web/srv-d74hd8v5r7bs73ctg8a0), open **Environment** and set `WRITE_MAINTENANCE=true`. The switch also accepts `1`, `yes`, and `on`, ignoring case and surrounding whitespace. Optionally set `WRITE_MAINTENANCE_MESSAGE` to a short public message. Select **Save and deploy** to reuse the existing build. It still runs the configured pre-deploy command, `db:safe_prepare`. If that command cannot finish, treat the switch as unapplied until you can verify a successful deploy. **Save only** stages changes for a later deploy, and **Restart service** reuses the live deploy's configuration. Verify the rollout and drain as described below before starting any migration.
2. **Suspend the worker.** Record the full approved release SHA and the current Start Command for [the payroll Solid Queue worker](https://dashboard.render.com/worker/srv-d75lj8muk2gs73dbg5og). Confirm automatic deploys are off. If the live worker SHA differs from the approved SHA, apply the guarded Start Command below before suspending. Substitute the full release SHA and the actual worker command. Wait for the guarded deploy to go **Live** and log the hold message on the live worker SHA, then suspend the service. If the worker is already on the approved SHA, suspend it directly. In both cases confirm the queue processes have exited and in-flight jobs have stopped. Confirm the web service uses `USE_SOLID_QUEUE=true` (the app default) and `SOLID_QUEUE_IN_PUMA=false` so it cannot run queued jobs itself. Account for any other operator or scheduled processes that write to the same tables.
3. **Deploy and migrate.** Keep the switch on for every web revision. Deploy the approved commit and let its pre-deploy `db:safe_prepare` finish. Verify the rollout again and run the probes below. During suspension, use the database checks in the dependency response to evaluate the migration.
4. **Run the release tasks and checks.** Run reconciliation and integrity checks with the worker still suspended. Keep maintenance enabled if any check fails. For a recovery revision, verify that it includes the switch and runs with the flag on. Update the worker's approved SHA before enabling its jobs.
5. **Turn off the switch.** Remove `WRITE_MAINTENANCE` or set it to `false`, remove any custom message, and select **Save and deploy** again. Wait for the rollout and verify the unauthenticated POST returns `401` again. Run a release-appropriate authenticated write smoke check.
6. **Deploy the worker on the release SHA.** Resume the worker with the guarded Start Command still configured if Step 2 installed it. Render cannot accept a deploy hook while the service is suspended. If the previous worker revision starts, verify it logs the hold message. Unless the worker is already live on the approved SHA, use the worker's **Manual Deploy → Deploy a specific commit** menu to select the full SHA verified on the web service. Verify the worker deploy is **Live** on that SHA and its logs show Solid Queue starting. The guard allows job execution only on that SHA. If the deploy fails, the old revision stays idle. Once the worker has a fresh heartbeat and the queue drains, restore its original Start Command if you installed the guard. If saving the command starts a deploy, confirm the linked branch points at the approved SHA before saving, and verify the resulting live SHA and heartbeat. Check pending and failed AIRE deliveries and any webhook or scheduled work due during the window. Replay unreceived events with their original idempotency keys when supported. Check recurring schedules for missed slots.

Guarded worker Start Command for a Git-backed Render service. This example uses `bundle exec bin/jobs` as the normal command.

```sh
if [ "$RENDER_GIT_COMMIT" = 'REPLACE_WITH_FULL_APPROVED_RELEASE_SHA' ]; then
  exec bundle exec bin/jobs
else
  echo "Payroll worker held on revision ${RENDER_GIT_COMMIT:-unknown}"
  exec sleep infinity
fi
```

See [Render environment settings](https://render.com/docs/configure-environment-variables#in-the-render-dashboard), [deploy and shutdown behavior](https://render.com/docs/deploys), and [deploy hook responses](https://render.com/docs/deploy-hooks).

### Verify rollout and drain without changing payroll data

Confirm the deploy is **Live** on the intended revision and check the Render logs for `[WriteMaintenance] enabled=true` on every replacement instance. Wait for each prior instance to exit. Allow at least 60 seconds after the final replacement becomes ready, and wait longer if the configured shutdown delay or the logs show draining is still in progress. A successful probe alone cannot verify instance coverage or that an in-flight write finished.

Run without credentials. The POST intentionally omits required data. On a service with multiple instances, repeat the POST across fresh connections and check the returned request IDs against each instance's logs. Use the deploy and per-instance logs to verify instances the probes did not reach.

```sh
base=https://cornerstone-payroll-api.onrender.com
curl -i "$base/up"
curl -i "$base/health/dependencies"
for probe in 1 2 3 4 5; do
  curl -i -X POST -H 'Connection: close' -H 'Content-Type: application/json' --data '{}' "$base/api/v1/admin/departments"
done
```

During the window, expect `/up` to return `200` and every POST to return `503` with `Retry-After: 60` and `"code":"write_maintenance"`. After reopening, expect the unauthenticated POST to return `401`.

While the worker is stopped, `/health/dependencies` will return `503` with `"status":"degraded"` and `"queue_worker":false` once its last heartbeat is removed or ages out after five minutes. The three primary database checks should be true before and after migration. After the approved worker revision starts and reports a fresh heartbeat, expect dependency health to return `200` with `"status":"ok"`.

## Scope and retry behavior

- The middleware rejects all methods except GET, HEAD, and OPTIONS under `/api/` and the Rails Active Storage and Action Mailbox route prefixes. This covers all roles, finance, multipart uploads, and both AIRE event webhook URLs. Read-oriented actions implemented as POST, such as some exports and previews, are also paused.
- The transmittal log, full print package, and check signoff report are paused on GET and HEAD because generating them persists payroll report state. Other reports follow their usual routes.
- Bound users can still sign in. New invitation binding returns a temporary error and leaves the invitation intact. After the window, the user can retry with the same Clerk session. If the invitation expired during the pause, an authorized administrator can use the existing Clerk account binding recovery flow. Closed practice logins remain denied, with account deactivation and any Clerk revocation deferred to the next normal access check or scheduled sweep.
- Existing previews and original files remain available. When a preview needs on-demand conversion, the request asks the reader to download the original or retry later instead of writing a preview record and uploading a file.
- Reads can still write operational metadata such as sign-in activity and access logs. Direct database sessions, Rails tasks, and requests to an external object store with previously issued upload URLs are outside the HTTP switch.
- A webhook receives `503` before any event is accepted. AIRE retains the event in its outbox and retries on its own schedule (exponential backoff capped at one hour). The interactive AIRE cutoff-change request reports temporary unavailability and needs a manual retry. Confirm other webhook senders' retry or replay behavior when planning a window. [AIRE outbox](https://github.com/Shimizu-Technology/aire-services/blob/2d23f9a51fb5d31ad9a1315683d6dfb38e0c280b/backend/app/services/payroll/outbox_dispatcher.rb) · [AIRE retry schedule](https://github.com/Shimizu-Technology/aire-services/blob/2d23f9a51fb5d31ad9a1315683d6dfb38e0c280b/backend/app/services/payroll/retry_schedule.rb) · [AIRE cutoff change](https://github.com/Shimizu-Technology/aire-services/blob/2d23f9a51fb5d31ad9a1315683d6dfb38e0c280b/backend/app/services/payroll/cutoff_change_client.rb)
- The switch reads the process environment on each request. This keeps write rejection independent of database availability or schema changes during a migration. Render applies environment changes by replacing the web process.
- Suspending the worker stops both the scheduler and queue consumers at the process level. Existing queued jobs stay in Solid Queue and run when the worker resumes. This also covers jobs outside `ApplicationJob` and avoids re-enqueue loops.
