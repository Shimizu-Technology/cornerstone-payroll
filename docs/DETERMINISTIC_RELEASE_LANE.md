# Deterministic payroll release lane

**Established:** August 23, 2026

This lane proves the highest-risk payroll workflow and trust boundaries against a disposable full stack. It starts Rails in the test environment, a Vite frontend, and PostgreSQL-backed synthetic data. It does not use a production account, production database, private payroll PDF, or long-lived bypass identity.

## What it proves

The browser suite fails rather than skips when its fixture or services are missing. It verifies:

- explicit synthetic admin and client identities, inactive-account rejection, staff-role denial, and cross-company isolation;
- client SSN masking and staff approval for payroll-sensitive changes;
- an unavailable time source without exposing its shared secret;
- calculate, approve, unapprove, reapprove, commit, reload, rejected recommit, and rejected post-commit edits;
- external-time import into an editable period and rejection after commit; and
- two pay periods in the same company and year can commit while sharing the correct annual YTD aggregates.

The backend suite separately generates deidentified, fixed-width Revel-shaped PDFs with Prawn and parses them through PDF::Reader. Those fixtures cover exact record counts and totals, regular and overtime columns, compressed fallback rows, multiline names, outlier rejection, and matching parsed names to persisted synthetic employees. No test reads `data/mosa-2025/raw`.

## Safety boundaries

`X-E2E-User-Email` is honored only when all three conditions are true: Rails is running in `test`, authentication is disabled, and `E2E_TEST_MODE=true`. Production always enables the normal authentication path. The seeder also refuses to run outside that exact test mode or against a database that already contains organizations, companies, users, employees, or pay periods.

The generated manifest contains synthetic IDs and `.example.test` addresses. It never contains the time-source secret. Playwright keeps the manifest outside `test-results`, because Playwright clears that directory at startup.

The release project has no retries. A partially completed payroll run must fail visibly instead of being retried against mutated database state.

## Local command

Use a dedicated database name. Never point this command at a shared development, staging, or production database.

```bash
createdb cornerstone_payroll_gate0_e2e

cd api
TEST_DATABASE_URL=postgres://localhost:5432/cornerstone_payroll_gate0_e2e \
RAILS_ENV=test \
AUTH_ENABLED=false \
E2E_TEST_MODE=true \
E2E_FIXTURE_PATH="$PWD/../web/.e2e-fixtures/release.json" \
bundle exec rails db:schema:load db:seed e2e:seed

cd ../web
TEST_DATABASE_URL=postgres://localhost:5432/cornerstone_payroll_gate0_e2e \
E2E_FIXTURE_PATH="$PWD/.e2e-fixtures/release.json" \
npm run test:e2e:release
```

Recreate and reseed the dedicated database before every fresh run. Drop only that exact task-owned database after testing.

## CI and release evidence

GitHub Quality runs three independent jobs:

- `backend`: schema-only database setup, the complete RSpec suite, Brakeman, and Bundler Audit;
- `frontend`: npm audit, typecheck, lint, production build, and public Playwright checks; and
- `browser`: fresh PostgreSQL, application seeds, the guarded synthetic fixture, Rails, Vite, and the no-retry Gate 0 suite.

The browser job retains the Playwright report, failure traces/screenshots/videos when present, and the non-secret synthetic manifest for 14 days. A release requires all three checks on the current PR head and a green resulting `main` commit. These checks do not replace the staging payroll, backup/restore, object storage, mail, queue, monitoring, MFA, or filing-output evidence in the production-readiness checklist.
