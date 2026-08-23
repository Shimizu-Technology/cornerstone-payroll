# Gate 0 trust and release plan

**Reviewed:** 2026-08-23

**Baseline:** `origin/main` at `c3ff96b`

**Status:** In progress; no item is closed until its acceptance evidence is linked below

## Purpose

Gate 0 establishes that Cornerstone Payroll revokes access correctly, preserves financial state under competing requests, treats external time as untrusted input, protects client payroll data, runs deterministic release tests, and has evidence for the production controls it claims.

Gate 0 does not complete liability settlement, direct deposit, historical QuickBooks migration, GL export, full quarterly/annual filing, Workforce productization, or general accounting. Those remain later phases in the payroll master plan.

## Completion rule

Gate 0 closes only when:

- every code finding below is merged with focused regression coverage;
- the complete local gate passes on each final PR head;
- relevant negative and browser tests pass;
- Greptile explicitly reports 5/5 on each final PR head with no actionable thread unresolved;
- required GitHub checks pass on an up-to-date PR head;
- the resulting `main` commit is green;
- authenticated payroll browser tests run in CI without a silent skip;
- production configuration and dependency probes pass in the actual environment; and
- the manual evidence checklist records an owner, date, environment, commit, result, and artifact for every operational control.

“Merged” closes code work. It does not close deployment, restore, filing, or operator evidence.

## Verified findings

| ID | Finding | Risk | Required outcome | State |
| --- | --- | --- | --- | --- |
| G0-01 | `main` resolves vulnerable `mail 2.9.0`; Quality is red | A known advisory is present and red main can become normal | Upgrade to a fixed version; full backend/frontend/security gates green | Code closed in PR #124; `main` green |
| G0-02 | `main` requires PRs but no current status checks | A PR can merge with stale results against an older base | Require backend/frontend checks and an up-to-date branch or merge queue | Closed in repository ruleset 2026-08-23 |
| G0-03 | HTTP auth accepts inactive users and inactive organizations | Deactivation does not revoke payroll access | Central active-account policy with verified Clerk identity and regression tests | Code closed in PR #125; `main` green |
| G0-04 | Action Cable accepts and retains inactive users | A deactivated user can retain live access | Apply the same policy to Cable and disconnect sessions after deactivation | Code closed in PR #125; `main` green |
| G0-05 | Clerk provisioning uses the first email without proving it is the verified primary address | The wrong email could link to an invited payroll account | Require Clerk's verified primary email | Code closed in PR #125; `main` green |
| G0-06 | Production encryption docs/readiness check environment keys that the initializer does not bind | Encrypted SSNs, bank data, secrets, or tokens can fail at runtime while readiness passes | One effective env-or-credentials contract; fail closed and test it | Code closed in PR #125; `main` green |
| G0-07 | Commit checks stale state before its transaction and does not lock the pay period | Concurrent requests can duplicate YTD/loan effects | Lock and revalidate; prove exactly-once outcomes with PostgreSQL concurrency tests | Code proposed in PR #126 |
| G0-08 | Approve, unapprove, calculation, item mutation, imports, and commit do not share one lifecycle lock boundary | A committed run can race back to editable state or be mutated during commit | Lock every financial transition/mutation in a consistent order | Code proposed in PR #126 |
| G0-09 | Time-source URL accepts unsafe HTTP/private destinations and sends the integration secret | SSRF, metadata access, secret disclosure, and response exfiltration | Admin-only config; production HTTPS/allowlist; DNS/IP pinning; safe response limits/errors | Open |
| G0-10 | Imported overtime uses a hard-coded Sunday week and can preserve source splits | Payroll is not reliably the legal overtime authority | Use the pay period's confirmed workweek and calculate the paid split in Payroll | Open |
| G0-11 | Workweek start minute is configurable but date-only code ignores it | UI claims unsupported non-midnight semantics | Implement timestamp boundaries or block non-midnight configuration | Open |
| G0-12 | Source day/category/regular/OT totals need not reconcile | Malformed payloads can inflate paid hours | Blocking invariants with tolerance and source evidence | Open |
| G0-13 | OCR apply can recreate an employee excluded from a pay period | Explicit operator exclusion can be bypassed | Share the same exclusion guard across all import paths | Code proposed in PR #126 |
| G0-14 | Client employee show returns full decrypted SSN | An assigned client account receives more identity data than needed | Never return a stored full SSN; use last four and replacement semantics | Open |
| G0-15 | Client portal directly applies pay, W-4, SSN, adjustments, and wage-rate changes | Client edits can change payroll math without Cornerstone approval | Direct-safe fields only; sensitive changes enter an auditable approval workflow | Open |
| G0-16 | Cornerstone Tax frontend fails open without Clerk configuration | A production configuration error can expose the application shell | Fail closed in production and test the missing-config state | Open |
| G0-17 | Authenticated Playwright normally skips because CI has no backend fixture/auth state | Release automation does not exercise payroll | Deterministic Postgres/Rails/Vite fixture and required journeys without skips | Open |
| G0-18 | Thirty production-data-dependent examples remain pending | Real import/calculation edge cases are not part of normal release proof | Deidentified production-shaped fixtures or a required secure validation lane | Open |
| G0-19 | Production readiness checks strings, not effective configuration or dependencies | A passing command can coexist with broken database/storage/queue/mail behavior | Validate effective config and live dependencies; retain manual restore/monitoring evidence | Open |
| G0-20 | Staff-role authority is broader than a documented field/action matrix | Accountants or managers may reach high-impact settings unintentionally | Review every high-impact endpoint and encode the approved role matrix | Open |

## Delivery sequence

Each row is a coherent PR or small PR group. A later group branches from updated `main` after the earlier group is merged.

1. **Release baseline and documentation**
   - Upgrade `mail` and restore green CI.
   - Establish this document, the product strategy, and documentation status vocabulary.
   - Configure required current checks after the first green PR proves the check names.
2. **Identity, session revocation, and encryption configuration**
   - G0-03 through G0-06.
3. **Payroll lifecycle locking and idempotency**
   - G0-07 and G0-08 across every transition and child mutation/import path.
4. **Time integration trust and correctness**
   - G0-09 through G0-13 plus a versioned integration contract.
5. **Client portal data and approval boundary**
   - G0-14 and G0-15.
6. **Cornerstone Tax fail-closed authentication**
   - G0-16 in the Cornerstone Tax repository.
7. **Deterministic browser and production-shaped verification**
   - G0-17 and G0-18.
8. **Operational readiness and role certification**
   - G0-19 and G0-20, followed by dated production evidence.

The sequence may split further when review shows a smaller safe unit. It must not split lifecycle locking so that some financial mutation paths remain raceable while the product is described as concurrency-safe.

## Financial lifecycle lock contract

All editable payroll mutations use the `pay_periods` row as their first serialization boundary. An operation must lock and reload that row before it decides whether the run is editable or whether a lifecycle transition is valid.

The covered mutation surface is:

- pay-period metadata changes, deletion, and `run_payroll` calculation;
- approve, unapprove, and commit transitions;
- payroll-item create, update, recalculate, exclusion, and removal;
- Revel/PDF payroll import apply;
- Payroll Intake apply;
- external time-tracking import apply;
- CSV timecard import apply; and
- OCR timecard apply.

Nested editable work follows `pay_period -> import/session -> payroll item`. Commit and void take shared financial rows in the deterministic order `pay_period -> employee YTDs by employee ID -> company YTD -> employee loans by employee and loan ID -> company check sequence -> payroll items`. The check-number worksheet also takes `pay_period -> company` so it cannot invert commit's locks. Every loan balance transition locks and reloads the loan before calculating its before/after values. Operations that intentionally rescue row-level failures use a savepoint so a rescued exception cannot commit half of an import or edit inside the outer lifecycle transaction. Commit owns status, YTD and loan effects, liability posting, check assignment, optional FIT check creation, correction audit, and tax-sync scheduling as one transaction.

Acceptance requires real PostgreSQL competing-thread tests for commit-versus-commit, commit-versus-unapprove, commit-versus-check-worksheet, payment-versus-payment, and payment-versus-loan-addition. The winner commits once; stale lifecycle transitions must reload the final state and receive an invalid-transition result. Final status, YTD totals, liabilities, loan balances, and check audit events must agree.

## Required browser and negative tests

The deterministic browser lane must cover at least:

- calculate, review, approve, and commit;
- double-click/retry commit without duplicate effects;
- unapprove before commit and immutable state after commit;
- time import into an editable period and rejection after commit;
- inactive user handling;
- client denial from staff routes and cross-company denial;
- client safe-field update versus approval-required payroll field;
- SSN masking/replacement behavior; and
- an unavailable or rejected integration destination without secret leakage.

Manual Computer Use testing supplements these checks. It does not replace executable regression coverage.

## Production evidence record

For each environment-specific control, record:

| Control | Owner | Environment | Commit | Verified at | Evidence link/location | Result | Retest date |
| --- | --- | --- | --- | --- | --- | --- | --- |
| MFA enforcement | Unassigned | Production | — | — | — | Not verified | — |
| Database backup and restore | Unassigned | Production-shaped isolated restore | — | — | — | Not verified | — |
| R2 upload/read/delete and recovery | Unassigned | Production | — | — | — | Not verified | — |
| Queue/cache/cable durability and restart | Unassigned | Production | — | — | — | Not verified | — |
| Email delivery and sender authentication | Unassigned | Production | — | — | — | Not verified | — |
| Error and uptime monitoring | Unassigned | Production | — | — | — | Not verified | — |
| Representative payroll lifecycle | Unassigned | Staging | — | — | — | Not verified | — |
| Filing-output certification | Cornerstone reviewer unassigned | Staging/official validator | — | — | — | Not verified | — |
| Incident and correction ownership | Unassigned | Operational policy | — | — | — | Not verified | — |

Repository evidence cannot prove these external controls. Missing evidence remains a no-go under the production readiness checklist.

## PR evidence template

Every Gate 0 PR description must include:

- intent and explicit non-goals;
- security/data-integrity facts the change depends on;
- focused regression tests;
- complete local gate output;
- browser/negative-test evidence where relevant;
- final PR head SHA;
- Greptile score and review head;
- required GitHub checks; and
- runtime, migration, deployment, and rollback impact.

## Closure log

Add one row after each merge. “Code closed” and “operationally closed” are deliberately separate.

| Finding(s) | PR | Merge commit | Code closed | Operational evidence | Notes |
| --- | --- | --- | --- | --- | --- |
| G0-01, G0-02 | #124 | `d59173e` | Yes | `main` Quality run 32615025379 passed; ruleset 16468532 now requires strict current-base `backend` and `frontend` checks | Dependency advisory cleared; browser authentication skip remains tracked as G0-17 |
| G0-03–G0-06 | #125 | `24b5c77` | Yes | `main` Quality run 32616646822 passed | Greptile 5/5 on head `cb20bed`; revocation is enforced at HTTP, Cable connection, retryable disconnect, and final broadcast delivery boundaries |
