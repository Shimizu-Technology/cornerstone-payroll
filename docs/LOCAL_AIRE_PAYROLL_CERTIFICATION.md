# Local Cornerstone–AIRE payroll certification

This drill proves the production-shaped two-system payroll contract without reading or changing production data. It creates two empty, temporary PostgreSQL databases; starts both Rails APIs on loopback-only ports; exercises the real HTTP boundary; and removes every database, process, log, fixture, shared secret, and delegation token when it exits.

Run it from the Cornerstone repository root:

```bash
AIRE_REPO_PATH=/absolute/path/to/aire-services \
  scripts/certify_aire_payroll_integration.sh
```

The drill fails closed unless both applications use Rails `test`, `E2E_TEST_MODE=true`, empty databases with the expected certification-only name prefixes, and free loopback ports. The fixture scripts refuse populated databases. The shared secret and one-time delegated AIRE token are generated for the run, stored only in the temporary directory, omitted from output, and trashed during cleanup.

## What a passing run proves

1. Cornerstone publishes the target and next semimonthly periods to AIRE. Scheduled regular paydays are the 15th and month-end, including holidays. Each cutoff is seven calendar days after the previous regular scheduled payday, at 17:00 Pacific/Guam.
2. Ordinary kiosk time is eligible without separate approval.
3. Manual time is held until Chels approves it from Cornerstone.
4. A long day below forty hours in its Sunday–Saturday week stays regular; overtime is calculated only above forty weekly hours.
5. A replayed approval is idempotent and a stale version is rejected.
6. Cornerstone can lock the due AIRE cutoff without opening AIRE.
7. AIRE creates an immutable Batch v2, retains excluded time, and delivers its finalized event to Cornerstone.
8. Cornerstone applies the authoritative AIRE batch, preserves its 14 regular + 0 overtime split, calculates payroll, approves it, and commits it.
9. Preparing a paper check leaves time unpaid. The explicit synthetic delivery event records payment for this test fixture.
10. AIRE receives imported, committed, and payment-issued acknowledgements while the held manual entry remains visible and unpaid in the finalized period.
11. The next published regular period shows that held entry as scheduled, still awaiting approval, and unpaid.
12. The source installation identity is pinned, historical pagination returns all three fixture entries and their permanent owner identities/current versions, and a mismatched installation is rejected over HTTP.

The manual reconciliation drill uses 32 prior hours and a ten-hour Thursday in the same workweek. It verifies the resulting 8 regular + 2 overtime hours across two checks, delivery, lost-response retry, and duplicate prevention.

No direct deposit, tax payment, filing, email, or production payroll action is part of this drill.

## Controlled test clock

The drill chooses a genuine fixed-policy cutoff at least 24 hours after the real current time. An external Ruby shim is loaded explicitly with `RUBYOPT` for both API processes and every Rails schema, seed, and runner invocation. It requires Rails `test`, `E2E_TEST_MODE=true`, a local certification-only `TEST_DATABASE_URL`, and a private, owned clock file. The clock file has mode `0600` inside the run's private temporary directory. The shim is never installed in application initializers or production code.

Both APIs begin two minutes before the selected 17:00 Guam cutoff. After the manual-time and overtime approval checks, the drill atomically advances their shared clock file to one second after cutoff. Finalization then runs over HTTP without waiting for the real date. Synthetic delivery uses the same fixture date. For example, a run on October 4, 2026 selects the October 7 cutoff after the September 30 regular scheduled payday, with an October 15 target payday and September 16–30 work period.

PostgreSQL `clock_timestamp()` remains real. Selecting a future cutoff keeps the fixture's real database revision timestamps before that cutoff. This run proves the fixed calendar policy and HTTP lifecycle; it does not prove that a database revision recorded after a real cutoff is excluded. The dedicated frozen-history tests must provide that separate evidence. The drill makes no source-time edits after advancing the synthetic clock.

The clock safety checks can run without databases or servers under each application's pinned Ruby:

```bash
ruby scripts/local_certification/test_clock.rb
```

## Browser review

Use `KEEP_RUNNING=true` when an operator needs to inspect the synthetic result in Cornerstone. Start the Cornerstone frontend separately against the printed API URL, use a disabled-auth local build, and open the printed pay-period ID. The APIs remain on the controlled fixture clock after the drill; this is suitable for reviewing synthetic operator state, with the database timestamp limitation above. Record the exact API process IDs, database names, ports, and fixture paths when handing the run to another reviewer. Stop the drill with Ctrl-C when the review is complete; its cleanup trap removes only the two processes and databases that run created.

## Production release boundary

A passing local drill certifies the software contract, not real payroll facts or production readiness. Production promotion still requires compatible AIRE and Cornerstone revisions, exact environment configuration, healthy schedulers/workers, read-only connectivity smoke tests, and named operator/recovery evidence. Never use this script with production database URLs, production shared secrets, real employee data, or a production pay period.
