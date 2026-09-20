# Local Cornerstone–AIRE payroll certification

This drill uses synthetic data to exercise the two-system payroll contract without reading or changing production data. It creates two empty, temporary PostgreSQL databases; starts both Rails APIs on loopback-only ports; exercises the real HTTP boundary; and removes the resources it created when it exits. It is not, by itself, proof that every payroll path works.

Run it from the Cornerstone repository root:

```bash
AIRE_REPO_PATH=/absolute/path/to/aire-services \
  scripts/certify_aire_payroll_integration.sh
```

The drill fails closed unless both applications use Rails `test`, `E2E_TEST_MODE=true`, empty databases with the expected certification-only name prefixes, and free loopback ports. The fixture scripts refuse populated databases. The shared secret and one-time delegated AIRE token are generated for the run, stored only in the temporary directory, omitted from output, and trashed during cleanup.

## Cutoff policy and test modes

A regular AIRE period is paid on its scheduled pay date and locks **seven calendar days later at 5 p.m. Guam**. The lock belongs to that same period; an adjustment run never moves it. Thus a finalized AIRE batch arrives after the normal payment. The connected pre-pay path must use a separately recorded live snapshot and reconcile it against the final batch later. A finalized-batch import cannot be the first source of hours for a normal on-time payment.

The full drill waits for its synthetic cutoff and tests finalization and event delivery. Set `BROWSER_REVIEW_ONLY=true` to stop before the cutoff and keep the synthetic APIs available for local UI review. This mode does **not** prove finalized-batch delivery or post-cutoff reconciliation. The synthetic pay date is chosen to put the cutoff near the test run; it is not a test of the real next-day pay schedule.

## What the full drill checks

1. Cornerstone publishes the current and next exact semimonthly Guam calendar periods with the pay-date-plus-seven cutoff.
2. Ordinary kiosk time is eligible without separate approval.
3. Manual time is held until Chels approves it from Cornerstone.
4. Daily overtime is detected by AIRE and remains held until Chels separately approves it from Cornerstone.
5. A replayed approval is idempotent and a stale version is rejected.
6. Cornerstone can lock the due AIRE cutoff without opening AIRE.
7. AIRE creates an immutable Batch v2, retains excluded time, and delivers its finalized event to Cornerstone.
8. Cornerstone applies the authoritative AIRE batch, preserves its 8 regular + 6 overtime split, calculates payroll, approves it, and commits it. This is a post-cutoff path in the synthetic drill, not the normal pre-pay sequence.
9. Preparing a paper check does not mark time paid. The explicit synthetic delivery event does.
10. AIRE receives imported, committed, and payment-issued acknowledgements while the held manual entry remains visible and unpaid in the finalized period.
11. The next published regular period shows that held entry as scheduled, still awaiting approval, and unpaid.

The separate browser-only review has exercised manual entry, check delivery, and exact AIRE paid-hour acknowledgement for 8 regular + 6 overtime hours. It has **not** exercised final event delivery. No direct deposit, tax payment, filing, email, or production payroll action is part of either mode.

## Browser review

Use `BROWSER_REVIEW_ONLY=true` when an operator needs to inspect the synthetic result in Cornerstone before the cutoff. Start the Cornerstone frontend separately against the printed API URL, use a disabled-auth local build, and open the printed pay-period ID. Stop the drill with Ctrl-C when the review is complete; its cleanup trap removes only the two processes and databases that run created.

## Production release boundary

A passing local drill supports only the behavior it actually exercises. Production promotion still requires compatible AIRE and Cornerstone revisions, exact environment configuration, healthy schedulers/workers, read-only connectivity smoke tests, and named operator/recovery evidence. The live pre-pay snapshot, direct-deposit confirmation, and final-versus-paid reconciliation need their own end-to-end tests before the connected path can be called ready. Never use this script with production database URLs, production shared secrets, real employee data, or a production pay period.
