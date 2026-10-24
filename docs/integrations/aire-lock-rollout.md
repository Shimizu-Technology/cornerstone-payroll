# AIRE manual-to-scheduled lock rollout

The approved activation date is October 16, 2026. New calendar publications for earlier period starts use `lock_mode: "manual"`; starts on or after activation use `"scheduled"`. October 1–15 retains its real October 22 nominal policy cutoff and can be published after that date. The accountant's explicit Lock freezes the approved revision at the moment of locking. Later approvals and corrections use settlement cases and the existing Pay late hours flow.

October 16–31 is paid November 15. Its contract requires the actual adjacent October 1–15 regular run and October 31 payday. Its scheduled cutoff is November 7 at 17:00 Pacific/Guam. Missing, ambiguous or shifted previous regular paydays remain publication errors. No dummy runs are created.

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
