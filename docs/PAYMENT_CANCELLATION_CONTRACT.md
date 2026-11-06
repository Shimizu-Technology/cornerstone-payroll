# Retiring a payment instrument while retaining payroll

Cornerstone owns earned payroll and the money calculation. A connected time system owns source hours. Retiring a check changes the payment instrument, while the committed payroll obligation and its reserved source hours remain intact. This operation is distinct from voiding payroll.

## Capability and ownership

The source must expose and verify `payment_cancellation_v1` in its pinned installation descriptor. The legacy AIRE profile does not grant this capability. The same contract applies to other connected producers. A wholly unprepared, unissued payment method change requires no cancellation receipt; prepared or issued connected checks require the capability, verified employee identity and exact original payment evidence before mutation.

Native bank confirmation, duplicate-linked checks and an unfinished cancellation block instrument changes. A same-method future-default update continues to use the existing atomic employee-default flow. Cancellation evidence must be trimmed, nonblank and at most 200 characters. Original instrument details and earned-pay amounts are retained in the audit.

## Imported exact-line receipts

An exact-line `2.0` receipt uses `status: payment_cancelled`, the original line UUID, source entry, line key, source kind, frozen REG/OT/total hours, payroll period/item and original paper-check tuple. Metadata includes `cancelled_payment_event_id`, `cancellation_evidence_reference` and `payroll_obligation_retained: true`.

The acknowledgement must include the verified installation descriptor and the exact `entry_processing` proof: event/status, all frozen line and owner fields, original method/reference/effective date, cancellation metadata and the cancellation timestamp. Timestamp comparison preserves six fractional digits and accepts equivalent explicit timezone offsets. Unknown legacy original effective dates stay unknown; producer metadata may report `original_payment_effective_on_known: false` and `original_payment_effective_on: null` while echoing the requested cancellation date.

Outbox dependencies are saved when each receipt is created. Cancellation waits for its prior original receipt to be delivered; replacement issuance waits for cancellation acknowledgement. Missing dependencies and mismatched acknowledgements remain retryable failures. Ordinary legacy receipt responses remain compatible.

## Manual allocations

Delegated `POST /api/v1/payroll/cockpit/manual_allocations/:id/cancel_payment` receives `command_id`, `expected_version`, `occurred_at`, `reason`, `cancellation_evidence_reference`, `payment_method`, `payment_reference` and optional `payment_effective_on`. Issued allocations return to committed. A committed allocation also accepts cancellation to fence an uncertain in-flight issuance. Neither transition releases its hours.

The acknowledgement binds `command.id` to the saved command and returns an immutable `manual_allocation` snapshot: ID, advancing integer version, committed status, source entry/version, employee UUID, work date, REG/OT and payroll period/item. Its `cancelled_payment` contains the source event ID/type, timestamp, original method/reference/effective date, evidence and reason. Generic producer versions must advance monotonically; the contract does not mandate a step size.

All active allocations receive durable cancellation intent. Original issuance intent is saved before HTTP and replayed to recover the source version if remote success was not saved locally. Cancellation intent is cleared, the full proof saved, and a fresh issuance command generated only after a validated acknowledgement is durably stored. Source replay returns the original cancellation proof even after replacement; a tombstone prevents stale issuance from resurrecting the original tuple.

## Concurrency and retained facts

A bounded per-payroll-item session advisory lock serializes native method mutations and remote manual transitions. It is acquired before row locks and released on success or failure. Short local transactions preserve intent across remote HTTP retries.

Retirement preserves committed payroll status, source UUID and work date, frozen REG/OT, gross/net/taxes and YTD earnings. Payment cancellation projects to `in_payroll`, with reserved hours and no paid claim. Independent payroll voiding retains its separate existing behavior.
