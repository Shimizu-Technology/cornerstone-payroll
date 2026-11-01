# AIRE manual-to-scheduled lock rollout

## Connected payroll pause during a coordinated release

Set `DEPLOYMENT_ENV=production` and `CONNECTED_PAYROLL_MODE=paused` on both apps **before** deploying this pair. Restart every web/worker process when changing the mode; it is a process environment setting. Production defaults to paused when the value is absent or unrecognized. Only the exact value `enabled` activates the connection. Development/test default to enabled when unset; an invalid explicit value pauses them too. Staging refuses boot without an explicit `enabled` or `paused` value. The lead must add `CONNECTED_PAYROLL_MODE=enabled` to the staging Render services before this release; this PR changes no hosted settings.

1. Record both approved commit SHAs, paired backups, operator and rollback/forward-recovery plan. Drain old connected workers and in-flight calls on both apps: old versions do not implement this setting. Verify both apps have the production/paused environment values.
2. Deploy and migrate AIRE first, keeping it paused. Verify every old AIRE worker is gone. Deploy and migrate Payroll, keeping it paused, and replace every old Payroll worker too.
3. Configure AIRE's `payroll:configure_lock_rollout` and Payroll's `aire_lock_rollout:configure` for every source with the same approved `STARTS_ON=2026-10-16`, identified actor and reason. Keep the inventory and history gates below; the pause switch does not waive them or rewrite old evidence.
4. Run `bundle exec rails connected_payroll:status` in **both web and worker environments**. Confirm `mode: paused` and `enabled: false`, approved builds, migrations, durable queue schema, worker heartbeats, recurring schedules and both lock-rollout receipts. Existing production/staging readiness JSON also exposes `connected_payroll`. Verify ordinary AIRE clock-in/out, edits and approvals and ordinary manual Payroll calculate/approve/commit/checks/reports using authorized fixtures.
5. Complete the [already-paid AIRE history release gate](#already-paid-aire-history-release-gate) while both apps remain paused and before publishing calendars. Stop activation on any mismatch.
6. Set `CONNECTED_PAYROLL_MODE=enabled` and restart all AIRE and Payroll processes in the controlled activation window. Enable both promptly: if only AIRE is enabled, Payroll returns retryable HTTP 503 until its restart completes. Verify both status outputs show enabled, then verify pending deliveries and exact payment receipts. Existing idempotency remains authoritative; do not delete pending work or fabricate receipts. Review any overdue scheduled cutoffs before activation: they become eligible immediately when enabled.

While paused, AIRE still records outbox evidence but does not reserve or deliver it, consume delivery attempts, or mark it failed. Automatic cutoff finalization and Payroll-initiated manual locks are held, even for existing calendars without a rollout singleton. Employee/kiosk notices suppress automatic-lock countdowns. Payroll holds calendar delivery, event verification, receipts, manual-allocation sync and calendar source refresh; one-shot jobs recheck in one minute without incrementing exception retry budgets, while recurring dispatchers wait for their next scheduled run. Connected endpoints return 503 with `Retry-After: 60` before partial writes, and Payroll exposes capability flags that disable connected imports/locks with “Connected payroll is paused.” Ordinary manual payroll and ordinary AIRE time tracking remain available. Pending evidence and ordering/idempotency rules survive a restart and resume; pre-existing failures still require their normal recovery.

A scheduled calendar that AIRE never accepted before its cutoff remains subject to the existing late-publication rejection after resume. The switch does not backdate an unpublished schedule or waive history/cutoff guards. Retain that pending evidence and resolve it through the approved operator recovery path; ordinary eligible pending deliveries still drain automatically.

No schema migration, secret rotation, hosted setting write or deployment is included in these PRs. This switch controls new processes; it cannot cancel a request already in flight or stop an old binary. Re-pause and restart both fleets before investigating a release problem, and retain all financial/source evidence.


The approved activation date is October 16, 2026. New calendar publications for earlier period starts use `lock_mode: "manual"`; starts on or after activation use `"scheduled"`. The contract supports an unpaid October 1–15 period retaining its October 22 nominal policy cutoff and an explicit Lock at the actual snapshot instant. **Production October 1–15 is already paid by #94 and must instead be recorded as already processed before activation; do not publish/Lock/import it again.** Later corrections use settlement cases and exact payment evidence.

October 16–31 is paid November 15. Its contract requires the actual adjacent October 1–15 regular run and October 31 payday. Its scheduled cutoff is November 7 at 17:00 Pacific/Guam. Missing, ambiguous or shifted previous regular paydays remain publication errors. No dummy runs are created.

## Already-paid AIRE history release gate

The November 2 read-only production inventory supplied by Leon has one August 1–15 AIRE batch (134 source rows and 134 entry processing events), committed #61 evidence, and no calendars. Payroll company 2 already paid August 16–31 (#67), September 1–15 (#76), September 16–30 (#86) and October 1–15 (#94). September adjustments #83 and #85 each cover one item; #68 covers August 1–15 and #69 July 16–31. AIRE's arbitrary-range preview can otherwise select old unbatched work as carryover. Published calendar selection is narrower, but it does not reconcile that history.

After deploying/configuring both apps, before activation and before any calendar publication:

1. Follow the AIRE repository's `backend/ops/release-day/README.md`. With Chels, fill the private plan from `paid-history-plan.example.json` using actual source-snapshot/commit ISO timestamps and exact integer AIRE IDs for #83/#85. Do not infer source hours from pay-run totals, use payday as the snapshot, or rewrite historical revisions.
2. From the deployed AIRE `backend/`, set `PAID_HISTORY_PLAN`, independently verified `EXPECTED_DB_HOST`/`EXPECTED_DB_NAME`, and authorized admin `ACTOR_ID`. Run `bin/rails runner ops/release-day/record-paid-history.rb`. It requires production, paused connection, October 16 rollout, zero calendars and the expected original batch inventory. Review and retain its hold IDs and `preview_digest`.
3. Run `APPLY=1 PREVIEW_DIGEST='<reviewed digest>' bin/rails runner ops/release-day/record-paid-history.rb`. One transaction holds July/earlier unrepresented eligible entries, entries edited after the reviewed snapshot and the #83/#85 adjustment entries as reported-paid/evidence-pending; then records the four regular ranges against #67/#76/#86/#94 through AIRE's supported manual-processing service, in date order. It creates no paid receipt, payment, or outbox event. Missing categories or inconsistent state stop and roll back the operation. Keep evidence holds until exact source-to-paycheck proof resolves them; they are not proof of issued payment.
4. Repeat the same command and expect `already_applied` with no extra records. Retain the audit receipt/checksums and verify five batches. AIRE blocks finalization if eligible old hours still lack baseline/allocation/hold coverage; newly approved old work can re-block the gate. Post-payment manual-batch changes become reviewable settlement cases requiring an explicit destination, rather than automatic full repayment.
5. Finish paused smoke checks, then activate both apps and publish **October 16–31 only**, before November 7, 17:00 Pacific/Guam. Its previous-period contract uses the real #94 run and October 31 payday; it does not require a replacement October 1–15 AIRE calendar. Backfilled historical ranges intentionally reject overlapping calendars. Verify current-period hours plus explicitly authorized correction deltas only, and retain normal Payroll historical-reconciliation/source-coverage gates. If an old publication already exists, stop for a reviewed recovery plan; never delete it to bypass overlap protection.

This procedure needs exact release-day evidence and the AIRE implementation PR in the final certified pair. It was implemented and tested only against synthetic local databases; no hosted access or writes were used.

## Configuration and deployment

Payroll migration `20261024092000` adds `time_tracking_sources.cutoff_enforcement_starts_on`, defaulting to the approved `2026-10-16` date. Model and PostgreSQL checks require a first/16th period start; AIRE sources cannot have a missing date. A database trigger prevents changing the configured date. Configuration is recorded in the append-only audit log with the boundary, system actor and approved rollout reason, including existing AIRE sources during migration. This is deliberately configure-once, which is stronger than preventing moves only after scheduled finalization.

Deploy the coordinated AIRE change and migrate first. Configure its installation singleton with an identified operator and reason before publishing new calendars:

```sh
bin/rails payroll:configure_lock_rollout STARTS_ON=2026-10-16 ACTOR='release operator' REASON='Approved October manual/scheduled lock rollout'
```

Before the AIRE-first window, disable Payroll calendar publication and drain/stop **old Payroll publication and delivery workers as well as old AIRE finalization workers**. Keep those old processes quiesced through AIRE migration/configuration and Payroll migration/configuration. Deploy matching web and worker releases before re-enabling either flow. An old Payroll publisher must not create or deliver an omitted-field publication during that window.

After Payroll migration, run its explicit gate for **each AIRE source**, using the same boundary as AIRE:

```sh
bin/rails aire_lock_rollout:configure SOURCE_ID=123 STARTS_ON=2026-10-16 ACTOR='release operator' REASON='Approved October manual/scheduled lock rollout'
```

This task validates the already configured, immutable boundary; it does not change it. It locks the inventory while checking every preactivation calendar and every publication revision, regardless of pending/failed/delivered/finalized state. Each must have explicit `lock_mode: "manual"` and the matching `cutoff_enforcement_starts_on`; a calendar without a publication also blocks. A newer valid publication does not excuse an older legacy revision. The task repeats these checks on **every invocation**, including idempotent configuration. A successful check appends `time_tracking_source#lock_rollout_gate_passed` with source, company, boundary, operator and reason. A failed check does not append a success receipt or rewrite evidence. Resolve any blocked inventory under a separately reviewed plan before proceeding; there is no automatic conversion or history rewrite.

The migration's default-date audit alone is not deployment acceptance. Leon's supplied read-only production inventory is zero Payroll publications, zero Payroll calendar periods and zero AIRE calendars; operators must verify and record that inventory again while old workers are stopped, then retain both applications' gate receipts. This implementation did not access production.

Payroll migration `20261025010000` adds one mutable JSONB cache, `time_tracking_sources.payroll_calendar_source_state`, default `{}`. It changes no publication payload, delivery snapshot, finalized event, checksum or frozen batch. AIRE independently validates the transmitted boundary/mode; Payroll rejects a delivery response that adopts another policy. Keep both sides on the same date. A new date requires a reviewed migration, not an ordinary settings edit. Never disable calendar or frozen-batch triggers.

No source hours, legacy mappings, historical payments, frozen payloads or prior publication evidence are rewritten. Existing history and source-coverage/historical-reconciliation gates still apply. A production clone needs its real source identity and reviewed historical reconciliation; activation does not certify old manually paid hours. Confirm the pay schedule and overtime workweek covering both October periods through normal setup.

## Calendar contract additions

- `lock_mode`: `manual` or `scheduled`, retained with the immutable publication.
- `cutoff_enforcement_starts_on`: `YYYY-MM-DD`, the independently validated boundary on both sides.
- `next_scheduled_cutoff_at`: AIRE's next unfinalized scheduled published cutoff, ISO 8601 or `null`. Manual periods do not contribute a cutoff; a delayed due scheduled period remains relevant. Payroll reads a mutable source-wide observation shared by all periods. It never uses a delivery-time publication snapshot or a local guess as the current value.
- `locked_at`: AIRE's actual frozen snapshot instant for a finalized manual period, with microsecond precision. Its batch cutoff must match this field. The calendar's `cutoff_at` remains the original nominal contract cutoff.

Pre-rollout scheduled publications on or after activation retain their original wire field set. Preactivation omitted-field evidence blocks the explicit deployment gate above. Rollout metadata alone does not request a revision. A legitimate future policy revision remains compatible with AIRE’s retained null per-period activation; new publications still require both explicit rollout fields.

Scheduled batches still require their batch cutoff to equal the published cutoff. A manual publication's delivery can retry after its nominal cutoff; the nominal instant does not expire an explicitly manual workflow. Importing remains frozen-batch-only. Lock, import, payroll commit and payment issuance remain separate saved actions.

Payroll UI changes are confined to the cockpit and calendar components, shared calendar copy and their types/tests. The pay-run Hours-step redesign remains a separate slice and should be rechecked after integration.

## Refresh contract

`POST /api/v1/admin/pay_periods/:id/aire_payroll_calendar/refresh` (also `/time_tracking_calendar/refresh`) returns HTTP 200 with both `aire_payroll_calendar` and `time_tracking_calendar` aliases of the presenter state. Payroll staff with access to that company may refresh. The existing authenticated client reads the latest delivered calendar on the linked source; its source-wide next cutoff updates all older pages too.

The presenter returns `next_scheduled_cutoff_at`, `next_scheduled_cutoff_status` (`available` or `unavailable`), and `next_scheduled_cutoff_refreshed_at`. `available` plus `null` means the source authoritatively reports no upcoming scheduled cutoff. `unavailable` plus `null` means no current source observation is usable; the UI must distinguish it from no upcoming cutoff. A missing field, invalid revision/timestamp or failed source request is unavailable. An unobserved cache has unavailable status and a null refresh timestamp.

Successful publication delivery records the source response under a source lock held through the request, preventing an older publication response from overwriting a newer reconciliation. A finalization callback immediately clears the shared cache to unavailable/null, then queues `AirePayrollCalendarSourceRefreshJob` for a fresh authenticated read. Queue or source failure cannot leave that finalized cutoff displayed; explicit refresh can recover. A source response that still points to a locally finalized scheduled period is unavailable. Publication payloads and delivery snapshots remain unchanged.

## Staging rehearsal and release evidence

1. In isolated staging, record release SHAs, source IDs, inventory counts and current database. Stop/drain the old Payroll publishers/delivery workers and old AIRE cutoff workers, and disable publication in both web releases.
2. Apply AIRE migrations and run its configure task. Apply Payroll migrations and run `aire_lock_rollout:configure` for each AIRE source. Retain operator/reason audit receipts before enabling either flow. Rerun both tasks and confirm the empty/explicit inventory still passes.
3. In disposable fixtures, show that a preactivation calendar without publications blocks Payroll configuration; also show a pending or delivered omitted-field publication blocks it even after a prior successful configuration. Show that a derived manual callback against that legacy publication remains rejected. Restore/reset only the disposable fixtures; do not rewrite real publication evidence.
4. Start matching new releases, publish October 1–15 manually and October 16–31 scheduled, and verify November 7 at 17:00 Guam. Refresh an older period's page, finalize the only scheduled period and verify available/null after source reconciliation. With a successor, verify the shared next cutoff advances on older pages. With source connectivity unavailable, verify unavailable/null immediately after callback and recover with explicit refresh.
5. Keep the coordinated release on hold until parent-owned connected/UI acceptance passes. If rolling back either application, disable publication and drain matching workers again; do not restart an old publisher against an activated AIRE installation.
