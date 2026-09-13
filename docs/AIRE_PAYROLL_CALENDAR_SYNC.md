# Cornerstone–AIRE payroll calendar sync

**Contract version:** `1.0`

**Business timezone:** `Pacific/Guam`

**Calendar owner:** Cornerstone Payroll
**Time-at-cutoff owner:** AIRE Services

## Implementation authority

- **Status:** Merged to `main`; production deployment and operator verification remain release gates.
- **Pull request:** [#190](https://github.com/Shimizu-Technology/cornerstone-payroll/pull/190)
- **Final merge commit:** `3ffb8f7475f0e34f73ed31980ed2007f33c20c33`
- **Code-complete scope:** Effective-dated T-7 settings, versioned calendar publication and retry, authenticated and idempotent finalization-event receipt, authoritative Batch v2 verification, durable evidence, role-aware UI state, and automated dispatchers.
- **Evidence still required:** Deployment migration evidence and a dated production operator test with Cornerstone and AIRE.
- **Changed risks:** The two applications now share versioned period identity, cutoff, and batch evidence. Clock skew, stale publications, tenant mismatch, payload drift, or an unavailable peer must fail visibly without changing payroll.
- **Next release gate:** Deploy both compatible sides, verify one synthetic future period end to end, then promote the Cornerstone AIRE payroll cockpit described in `AIRE_PAYROLL_COCKPIT.md`.

This contract lets Chels schedule AIRE payroll from Cornerstone without making either system depend on the other at the cutoff instant. Cornerstone publishes the approved pay-period dates. AIRE locks the eligible time autonomously, retains everything that was held, and sends Cornerstone an immutable finalization event.

## Policy enforced by the contract

- AIRE regular payroll is semimonthly: the 1st–15th and the 16th–last day of the month.
- The cutoff is seven calendar days before the pay date in Guam. The cutoff time is an explicit, effective-dated company setting; the default is 5:00 PM.
- Normal clock and kiosk entries are eligible without another approval. Manual or manually corrected time must be approved in AIRE before cutoff.
- Late, open, unapproved, denied, and otherwise ineligible time remains visible with its reason. It is not silently deleted or added to the locked batch.
- Publishing a calendar does not import time, calculate payroll, issue a check, or mark wages paid.
- Finalizing an AIRE batch does not mean Cornerstone processed or paid it. Payment state is reported separately by the existing processing-event contract.
- Direct deposit is outside this implementation.

## State flow

1. A manager or admin confirms Cornerstone's effective-dated pay schedule, legal workweek, and cutoff time.
2. Cornerstone creates a versioned publication and sends it to AIRE with a stable external period ID and idempotency key.
3. AIRE validates the semimonthly dates and Guam T-7 rule, retains the revision, and owns autonomous finalization from that point forward.
4. At cutoff, AIRE creates one immutable Batch v2 and one durable `payroll_batch.finalized` outbox event in the same transaction.
5. Cornerstone receives the event idempotently, checks that it belongs to the latest delivered calendar revision, and fetches the authoritative Batch v2 from AIRE.
6. Cornerstone validates the full batch, checksum, totals, issues, period dates, and source identity before showing **Batch verified**.
7. Cornerstone's AIRE payroll cockpit shows the verified batch and payment history. Verification alone never changes payroll.

## Cornerstone endpoints

The pay-run UI uses these authenticated staff endpoints:

- `GET /api/v1/admin/pay_periods/:pay_period_id/aire_payroll_calendar`
- `POST /api/v1/admin/pay_periods/:pay_period_id/aire_payroll_calendar/publish`
- `POST /api/v1/admin/pay_periods/:pay_period_id/aire_payroll_calendar/retry_delivery`

Accountants may read the state. Publishing, revising, and manually retrying delivery require the existing client-configuration permission.

AIRE sends finalization events to this service endpoint:

- `POST /api/v1/integrations/aire/events`

The request must include the source's shared secret and an `Idempotency-Key` equal to the event UUID. The receiver accepts only contract version `1.0`, source `aire_services`, event type `payroll_batch.finalized`, the latest delivered publication, and Batch v2 metadata. Repeating the same event and contents is safe. Reusing an event ID for different contents, or sending a second event ID for the same batch, returns `409 Conflict`.

## Durable evidence and retries

Calendar publications and inbound events are append-only. Source payloads, checksums, identities, and version links cannot be edited after creation. A delivered publication and a verified event are final.

Both directions retain failures and retry with bounded backoff. A recurring dispatcher reserves due rows before queueing them, releases the reservation if queue submission fails, and prevents concurrent dispatcher sweeps from enqueueing the same row twice. Operator-visible state distinguishes:

- not published;
- publishing or delivery failed;
- scheduled or cutoff due;
- batch verification in progress or retrying;
- permanent contract mismatch requiring review; and
- verified immutable batch.

Calendar delivery retries stop automatically at cutoff so a disconnected integration cannot create a late lock. The failed publication remains visible, and a manager can deliberately retry it after confirming AIRE's state. Verification transport failures continue retrying indefinitely at a capped six-hour delay because verification is read-only and critical evidence must self-heal after an extended AIRE outage. A deterministic contract mismatch is rejected immediately instead of retried.

A rejected batch is a terminal integrity result, not a transient retry state. It means AIRE's authoritative Batch v2 no longer matches the immutable event or published calendar. Cornerstone must not override that evidence or accept rewritten contents under the same batch identity. An operator should deactivate a compromised connection if appropriate, retain both systems' audit records, and create a correction or supplemental period with a new calendar publication and new AIRE batch identity. The pay-run card keeps the rejection and its bounded error visible until that recovery is completed.

Error text returned to the browser is bounded and never stores or displays an AIRE response body. A production source must use the existing secure destination policy; localhost is permitted only in local development and test.

## Change and correction rules

Before cutoff, a date change creates the next schedule revision. Repeating unchanged contents reuses the same publication. At or after cutoff, Cornerstone blocks changes to the published start date, end date, or pay date. Operators must use a correction or supplemental run so the original time and payroll evidence remains explainable.

Cornerstone also refuses to create a first publication after its cutoff. This avoids recording a local publication that AIRE must reject as undeliverable.

## Operational checks

Before deploying this phase:

- run the migration up, down, and up again on a disposable database;
- load `schema.rb` into an empty database and verify the calendar tables, unique batch index, cutoff defaults, and pre-existing employee-document append-only trigger;
- run the complete Rails and frontend suites, static analysis, dependency audits, and production builds;
- run both applications locally with the same synthetic shared secret;
- publish a future period from the Cornerstone pay-run page in Chrome;
- verify AIRE retained the exact revision;
- advance the synthetic workflow through AIRE finalization and event delivery; and
- verify Cornerstone shows the authoritative batch as verified without claiming it was imported, processed, or paid.

The AIRE-side authority is `docs/PAYROLL_CALENDAR_CONTRACT.md` in the `aire-services-Guam` repository. The immutable hours payload remains governed by [AIRE finalized payroll batch import](AIRE_FINALIZED_BATCH_IMPORT.md).
