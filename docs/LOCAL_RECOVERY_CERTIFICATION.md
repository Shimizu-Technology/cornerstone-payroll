# Local payroll recovery certification

These drills verify recovery mechanics with synthetic data on isolated local resources. They do not read or mutate production payroll and do not replace provider backup, object-version recovery, named reviewer, or staging evidence required by the production readiness checklist.

## Database backup and restore

Run from the repository root:

```bash
scripts/certify_database_restore.sh
```

The script creates an empty database whose name begins with `cornerstone_recovery_src_`, loads the current schema and deterministic release fixture, creates a custom-format `pg_dump`, and restores it into a new `cornerstone_recovery_dst_` database. It compares schema-migration identity, a deterministic digest of the restored application rows, and the counts for companies, employees, pay periods, payroll items, audit logs, filing records, and operational queue probes. Both databases and the temporary dump are removed when the comparison finishes.

The initial September 14, 2026 drill on Cornerstone revision `5684338d9689c6ebe71e1f9cd8fe05b0a73575e1` passed:

- backup size: `852328` bytes;
- backup SHA-256: `0c5234bc949ef32e533f1d0ccc35eb462eee3bc0bd7b70395e273cf3a8193606`;
- source and restore counts: 2 companies, 8 employees, 7 pay periods, 5 payroll items, 1 audit log, and 0 filing records; and
- schema migration identity: 193 versions through `20260914060000`.

This is local procedural evidence only. Production acceptance still requires an encrypted provider backup restored into a restricted isolated provider database, a second reviewer, source-point reconciliation, and documented destruction or retention.

The repeatable script was rerun after adding the queue probe schema and passed with 194 migrations through `20260914070000`. The source and restored databases both contained 2 companies, 8 employees, 7 pay periods, 5 payroll items, 1 audit log, 0 filing records, and 0 queue-probe records.

## Queue restart and duplicate prevention

Run from the repository root:

```bash
scripts/certify_queue_restart.sh
```

The script creates a uniquely named empty test database, loads the application and Solid Queue schemas, starts a loopback-only web process, and enqueues a non-payroll operational probe while no worker is running. It then stops and restarts the web process, starts the worker, and proves the queued probe completes. Replaying the same UUID produces a second recorded attempt while the database-enforced effect count remains exactly one and its completion timestamp remains unchanged. The exact probe row, database, processes, logs, and temporary directory are removed on exit.

The drill fails closed unless Rails is in `test`, the database has the certification-only prefix, the selected port is free, and every expected transition is observed. It never sends email, creates a payroll record, contacts AIRE, or accesses a production service.

The September 14, 2026 local drill passed with two different web process IDs, one worker process, two executions of the same UUID, and one durable effect.

Passing locally proves the queue and idempotency mechanism on the release code. The production gate still requires the equivalent synthetic staging exercise with named operator and reviewer evidence.
