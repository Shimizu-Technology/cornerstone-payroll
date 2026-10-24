# Pay late hours

Chels can open **Pay late hours** in a connected regular payroll's **Held time** area, select approved unpaid cases and confirm a pay date. Payroll creates a separate adjustment with only those source lines. The original cutoff batch remains frozen.

The adjustment captures the Payroll employee earning rates on creation. Normal calculate, approve, commit, check preparation and issuance continue to apply. Committing wages does not mark them paid. Exact per-line imported, committed, prepared and issued receipts use the existing outbox. Supplemental runs send no aggregate acknowledgements.

## Additive AIRE contract

Requires AIRE PR #141. GET `/api/v1/payroll/cockpit/periods/:external_pay_period_id/late_hours` supplies eligible unassigned cases with optimistic case and origin-period versions and exact positive lines. POST accepts the selected case IDs/versions, a stable command UUID, expected period version, reason, target adjustment ID and pay date. It atomically claims a separate immutable supplemental schema-2 batch. Response is the existing export payload inside `payroll_batch`; idempotent replay returns the same snapshot. Regular batch discovery remains unchanged.

Payroll saves its operation, destination and captured rate/employee selection before the remote call. Network failure leaves a resumable named adjustment. Recovery retains the original command, destination and rates; the current authorized accountant uses their own identity. Returned source lines must match the reviewed entry IDs, employee UUIDs, versions, dates, category and exact hour components. Mapping/pay-basis changes hold recovery. A returned immutable snapshot is retained even when validation/import fails. An incomplete or closed operation cannot calculate or finalize. Existing source conservation protects applied hours and rates; unrelated employee pay requires another run.

POST `/api/v1/payroll/cockpit/periods/:origin/late_hours/:source_command_id/recover` accepts a fresh command UUID, current origin period version, reason and original target ID. It returns `claimed` with the immutable snapshot, `no_claim`, or `canceled`. AIRE durably fences the original command and target before returning `no_claim`; a timeout, HTTP conflict or bare absence is never enough to release local intent. A definitive create rejection triggers this reconciliation. Successful no-claim recovery closes the operation as `rejected` and permits a fresh selection with a new command/adjustment. Accountants can recover another operator's claim after the creator loses access, with current grants rechecked rather than impersonating the creator.

For an accepted but unusable unapplied claim, **Review cancellation** requires an explicit reason. Payroll holds the operation and adjustment locks, verifies no items/imports/applied data, and posts `/cancel` with a fresh command, current period version, original target, exact `expected_batch_id` and `confirm_unapplied:true`. Only AIRE's confirmed `canceled` response closes the operation as `cancelled`. AIRE refuses any existing import, commit, payment or financial evidence. Failure/ambiguity keeps the reservation. Immutable snapshots and audit history remain; the empty closed adjustment is retained as evidence. Imported payroll uses the normal correction flow. Pending operations block their conflicting cases/source entries; unrelated eligible hours remain selectable.

AIRE rejects represented source work, active manual reservations, other routing, nonpayable/denied/pending hours, stale versions and unresolved due-cutoff claims, including frozen zero-pay states that could otherwise reverse a later supplement. Exact-line receipts must name the original supplemental owner or a successor validated by the existing immutable obligation-correction chain, with its correct payroll item. Additional payable dates from overnight source splits retain their source workweek and carryover identity; the validator allows the source split day immediately after the nominal origin end date only for named supplemental payloads.

Permissions reuse the company's Client management grant for creation, recovery and cancellation. Accountants without that grant cannot issue these commands. The operator also needs their existing connected AIRE authority.

## Migration and rollout

Payroll migration `20261024060000` adds `time_tracking_late_hours_runs`, with source-command uniqueness, a unique adjustment destination and foreign keys. Migration `20261024070000` adds audited recovery state, resolution evidence/time/operator and a state constraint; existing applied operations become `applied`, other existing operations become `ambiguous`. Payroll history and intent/rate snapshots stay unchanged. AIRE has its own partial-index and append-only retirement migrations in #141. Deploy AIRE's migrations and recovery/cancel/receipt behavior before exposing Payroll's recovery controls, then apply Payroll's migrations. Do not run migrations against staging or production as part of this task.

## Verification

Evidence and the exact final-head gate/QA ledger are in the task output directory:
`output/payroll-aire-review-2026-10-24/impl/late-hours/`.

Focused request/service/UI tests cover exact four-hour adjustment, captured-rate retry after ambiguous network failure, source mutation refusal, permission enforcement, duplicate commands, extra-source response rejection, incomplete-import holds, overnight split dates, source-only pay and normal calculation/commit receipts. Connected headless browser acceptance uses synthetic independent databases at 1280×800 and 390×844, including reload and synthetic check issuance. No physical printer, native mobile, real payments, filing or email providers are exercised.
