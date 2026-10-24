# Pay late hours

Chels can open **Pay late hours** in a connected regular payroll's **Held time** area, select approved unpaid cases and confirm a pay date. Payroll creates a separate adjustment with only those source lines. The original cutoff batch remains frozen.

The adjustment captures the Payroll employee earning rates on creation. Normal calculate, approve, commit, check preparation and issuance continue to apply. Committing wages does not mark them paid. Exact per-line imported, committed, prepared and issued receipts use the existing outbox. Supplemental runs send no aggregate acknowledgements.

## Additive AIRE contract

Requires AIRE PR #141. GET `/api/v1/payroll/cockpit/periods/:external_pay_period_id/late_hours` supplies eligible unassigned cases with optimistic case and origin-period versions and exact positive lines. POST accepts the selected case IDs/versions, a stable command UUID, expected period version, reason, target adjustment ID and pay date. It atomically claims a separate immutable supplemental schema-2 batch. Response is the existing export payload inside `payroll_batch`; idempotent replay returns the same snapshot. Regular batch discovery remains unchanged.

Payroll saves its operation, destination and captured rate/employee selection before the remote call. Network failure leaves a resumable named adjustment. Retries use the same command, destination and rates. Returned source lines must match the reviewed entry IDs, employee UUIDs, versions, dates, category and exact hour components. Mapping/pay-basis changes hold recovery. An incomplete operation cannot calculate or finalize. Existing source conservation protects applied hours and rates; unrelated employee pay requires another run.

AIRE rejects represented source work, active manual reservations, other routing, nonpayable/denied/pending hours, stale versions and unresolved due-cutoff claims. Exact-line receipts must name the saved supplemental destination and correct payroll item. Additional payable dates from overnight source splits retain their source workweek and carryover identity; the validator allows the source split day immediately after the nominal origin end date only for named supplemental payloads.

Permissions reuse the company's Client management grant, including creation and resumption. Accountants without that grant cannot issue either command. The operator also needs their existing connected AIRE authority.

## Migration and rollout

Payroll migration `20261024060000` adds `time_tracking_late_hours_runs`, with source-command uniqueness, a unique adjustment destination and foreign keys. It is additive and does not rewrite payroll history. AIRE has its own additive/partial-index migration in #141. Apply both migrations and deploy AIRE's additive endpoint before exposing the Payroll action; older AIRE installations return a recoverable unavailable-source message. Do not run this migration against staging or production as part of this task.

## Verification

Evidence and the exact final-head gate/QA ledger are in the task output directory:
`output/payroll-aire-review-2026-10-24/impl/late-hours/`.

Focused request/service/UI tests cover exact four-hour adjustment, captured-rate retry after ambiguous network failure, source mutation refusal, permission enforcement, duplicate commands, extra-source response rejection, incomplete-import holds, overnight split dates, source-only pay and normal calculation/commit receipts. Connected headless browser acceptance uses synthetic independent databases at 1280×800 and 390×844, including reload and synthetic check issuance. No physical printer, native mobile, real payments, filing or email providers are exercised.
