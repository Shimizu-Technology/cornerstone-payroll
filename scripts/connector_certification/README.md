# Independent payroll producer certification

This fixture proves that a compatible time-tracking application can use the same Cornerstone workflow as AIRE. It runs a separate Python HTTP producer with a Monday-start weekly UTC policy, rather than reusing AIRE code or mocking Cornerstone's HTTP client.

Run `scripts/certify_independent_payroll_connector.sh` with the repository's pinned Ruby and local PostgreSQL available. Set `NEUTRAL_CERTIFICATION_RESULT` to a new private JSON path outside a Git checkout to retain the certificate. The script refuses an occupied producer port, an existing output, a dirty tracked application checkout, or a nonempty application database. `PAYROLL_REPO_PATH` can select the immutable application checkout being certified.

The test publishes a confirmed company calendar, freezes an immutable checksum-backed batch, imports 45 original hours as 40 regular and 5 overtime hours, calculates $1,187.50 gross, commits payroll, and records synthetic check delivery. Every issued receipt must match exactly one immutable source line and its original employee UUID, hours, company, payroll run, payroll item, check reference, and delivery date. A second company with an overlapping numeric source employee ID must remain unaffected.

Producer tests also exercise authentication, installation pinning, policy rejection, calendar replay and frozen revision rejection, checksum integrity, changed receipt replay, and receipt identity mismatches. Unadvertised manual workflows remain unavailable. AIRE's paired certification covers its own manual and direct processing flows; this independent fixture does not claim that a real operator has accepted either workflow.

All data is synthetic. The clock override exists only in the guarded disposable test process. The script binds the producer to loopback, creates one uniquely named database, and removes its own process, database, and temporary files. Cleanup failures return a failure and identify retained private diagnostics. Shared local services are left running.

The exact-pair GitHub workflow runs this independent lane in addition to the AIRE lane. It retains the result and binds its SHA-256 into the pair certificate. A passing result is application compatibility evidence; production reconciliation approval, authentication isolation, and actual operator acceptance remain release decisions.
