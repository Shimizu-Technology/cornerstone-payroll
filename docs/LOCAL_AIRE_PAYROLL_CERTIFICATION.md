# Local Cornerstone–AIRE payroll certification

This drill proves the production-shaped two-system payroll contract without reading or changing production data. It creates two empty, temporary PostgreSQL databases; starts both Rails APIs on loopback-only ports; exercises the real HTTP boundary; and removes every database, process, log, fixture, shared secret, and delegation token when it exits.

Run it from the Cornerstone repository root:

```bash
AIRE_REPO_PATH=/absolute/path/to/aire-services \
  scripts/certify_aire_payroll_integration.sh
```

The drill fails closed unless both applications use Rails `test`, `E2E_TEST_MODE=true`, empty databases with the expected certification-only name prefixes, and free loopback ports. The fixture scripts refuse populated databases. The shared secret and one-time delegated AIRE token are generated for the run, stored only in the temporary directory, omitted from output, and trashed during cleanup.

## What a passing run proves

1. Cornerstone publishes an exact semimonthly Guam T-7 calendar to AIRE.
2. Ordinary kiosk time is eligible without separate approval.
3. Manual time is held until Chels approves it from Cornerstone.
4. Daily overtime is detected by AIRE and remains held until Chels separately approves it from Cornerstone.
5. A replayed approval is idempotent and a stale version is rejected.
6. Cornerstone can lock the due AIRE cutoff without opening AIRE.
7. AIRE creates an immutable Batch v2, retains excluded time, and delivers its finalized event to Cornerstone.
8. Cornerstone applies the authoritative AIRE batch, preserves its 8 regular + 6 overtime split, calculates payroll, approves it, and commits it.
9. Preparing a paper check does not mark time paid. The explicit synthetic delivery event does.
10. AIRE receives imported, committed, and payment-issued acknowledgements while the held manual entry remains visible and unpaid for a later period.

No direct deposit, tax payment, filing, email, or production payroll action is part of this drill.

## Browser review

Use `KEEP_RUNNING=true` when an operator needs to inspect the synthetic result in Cornerstone. Start the Cornerstone frontend separately against the printed API URL, use a disabled-auth local build, and open the printed pay-period ID. Stop the drill with Ctrl-C when the review is complete; its cleanup trap removes only the two processes and databases that run created.

## Production release boundary

A passing local drill certifies the software contract, not real payroll facts or production readiness. Production promotion still requires compatible AIRE and Cornerstone revisions, exact environment configuration, healthy schedulers/workers, read-only connectivity smoke tests, and named operator/recovery evidence. Never use this script with production database URLs, production shared secrets, real employee data, or a production pay period.
