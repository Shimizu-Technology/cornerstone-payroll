# AIRE manual-to-scheduled lock rollout

The approved activation date is October 16, 2026. New calendar publications for earlier period starts use `lock_mode: "manual"`; starts on or after activation use `"scheduled"`. October 1–15 retains its real October 22 nominal policy cutoff and can be published after that date. The accountant's explicit Lock freezes the approved revision at the moment of locking. Later approvals and corrections use settlement cases and the existing Pay late hours flow.

October 16–31 is paid November 15. Its contract requires the actual adjacent October 1–15 regular run and October 31 payday. Its scheduled cutoff is November 7 at 17:00 Pacific/Guam. Missing, ambiguous or shifted previous regular paydays remain publication errors. No dummy runs are created.

## Configuration and deployment

Payroll migration `20261024092000` adds `time_tracking_sources.cutoff_enforcement_starts_on`, defaulting to the approved `2026-10-16` date. Model and PostgreSQL checks require a first/16th period start; AIRE sources cannot have a missing date. A database trigger prevents changing the configured date. Configuration is recorded in the append-only audit log with the boundary, system actor and approved rollout reason, including existing AIRE sources during migration. This is deliberately configure-once, which is stronger than preventing moves only after scheduled finalization.

Deploy the coordinated AIRE change and migrate first. Configure its installation singleton with an identified operator and reason before publishing new calendars:

```sh
bin/rails payroll:configure_lock_rollout STARTS_ON=2026-10-16 ACTOR='release operator' REASON='Approved October manual/scheduled lock rollout'
```

Drain old AIRE workers and run the matching web/worker release before enabling the new publication flow. Then migrate and deploy Payroll. AIRE independently validates the transmitted boundary/mode; Payroll rejects a delivery response that adopts another policy. Keep both sides on the same date. A new date requires a reviewed migration, not an ordinary settings edit. Never disable calendar or frozen-batch triggers.

No source hours, legacy mappings, historical payments, frozen payloads or prior publication evidence are rewritten. Existing history and source-coverage/historical-reconciliation gates still apply. A production clone needs its real source identity and reviewed historical reconciliation; activation does not certify old manually paid hours. Confirm the pay schedule and overtime workweek covering both October periods through normal setup.

## Calendar contract additions

- `lock_mode`: `manual` or `scheduled`, retained with the immutable publication.
- `cutoff_enforcement_starts_on`: `YYYY-MM-DD`, the independently validated boundary on both sides.
- `next_scheduled_cutoff_at`: AIRE's next unfinalized scheduled published cutoff, ISO 8601 or `null`. Manual periods do not contribute a cutoff; a delayed due scheduled period remains relevant. Payroll's presenter forwards source state and can fall back to its retained scheduled publications.
- `locked_at`: AIRE's actual frozen snapshot instant for a finalized manual period, with microsecond precision. Its batch cutoff must match this field. The calendar's `cutoff_at` remains the original nominal contract cutoff.

Pre-rollout scheduled publications retain their original wire field set. Rollout metadata alone does not request a revision. A legitimate future policy revision remains compatible with AIRE’s retained null per-period activation; new publications still require both explicit rollout fields.

Scheduled batches still require their batch cutoff to equal the published cutoff. A manual publication's delivery can retry after its nominal cutoff; the nominal instant does not expire an explicitly manual workflow. Importing remains frozen-batch-only. Lock, import, payroll commit and payment issuance remain separate saved actions.

Payroll UI changes are confined to the cockpit and calendar components, shared calendar copy and their types/tests. The pay-run Hours-step redesign remains a separate slice and should be rechecked after integration.
