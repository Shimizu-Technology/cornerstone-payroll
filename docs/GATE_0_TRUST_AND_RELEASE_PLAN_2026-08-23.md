# Gate 0 trust and release plan

**Reviewed:** 2026-08-23

**Baseline:** re-audited against `origin/main` through `2d849b9`

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
| G0-07 | Commit checks stale state before its transaction and does not lock the pay period | Concurrent requests can duplicate YTD/loan effects | Lock and revalidate; prove exactly-once outcomes with PostgreSQL concurrency tests | Code closed in PR #126; `main` green |
| G0-08 | Approve, unapprove, calculation, item mutation, imports, and commit do not share one lifecycle lock boundary | A committed run can race back to editable state or be mutated during commit | Lock every financial transition/mutation in a consistent order | Code closed in PR #126; `main` green |
| G0-09 | Time-source URL accepts unsafe HTTP/private destinations and sends the integration secret | SSRF, metadata access, secret disclosure, and response exfiltration | Admin-only config; production HTTPS/allowlist; DNS/IP pinning; safe response limits/errors | Code closed in PR #127; `main` green |
| G0-10 | Imported overtime uses a hard-coded Sunday week and can preserve source splits | Payroll is not reliably the legal overtime authority | Use the pay period's confirmed workweek and calculate the paid split in Payroll | Code closed in PR #128; `main` green |
| G0-11 | Workweek start minute is configurable but date-only code ignores it | UI claims unsupported non-midnight semantics | Implement timestamp boundaries or block non-midnight configuration | Code closed in PR #128; `main` green |
| G0-12 | Source day/category/regular/OT totals need not reconcile | Malformed payloads can inflate paid hours | Blocking invariants with tolerance and source evidence | Code closed in PR #128; `main` green |
| G0-13 | OCR apply can recreate an employee excluded from a pay period | Explicit operator exclusion can be bypassed | Share the same exclusion guard across all import paths | Code closed in PR #126; `main` green |
| G0-14 | Client employee show returns full decrypted SSN | An assigned client account receives more identity data than needed | Never return a stored full SSN; use last four and replacement semantics | Code closed in PR #130; `main` green |
| G0-15 | Client portal directly applies pay, W-4, SSN, adjustments, and wage-rate changes | Client edits can change payroll math without Cornerstone approval | Direct-safe fields only; sensitive changes enter an auditable approval workflow | Code closed in PR #130; `main` green |
| G0-16 | Cornerstone Tax frontend fails open without Clerk configuration | A production configuration error can expose the application shell | Fail closed in production and test the missing-config state | Code closed in Cornerstone Tax PR #53; production signed-out routes verified |
| G0-17 | Authenticated Playwright normally skips because CI has no backend fixture/auth state | Release automation does not exercise payroll | Deterministic Postgres/Rails/Vite fixture and required journeys without skips | Code closed in PR #131; `main` green |
| G0-18 | Thirty production-data-dependent examples remain pending | Real import/calculation edge cases are not part of normal release proof | Deidentified production-shaped fixtures or a required secure validation lane | Code closed in PR #131; `main` green |
| G0-19 | Production readiness checks strings, not effective configuration or dependencies | A passing command can coexist with broken database/storage/queue/mail behavior | Validate effective config and live dependencies; retain manual restore/monitoring evidence | Open |
| G0-20 | Staff-role authority is broader than a documented field/action matrix | Accountants or managers may reach high-impact settings unintentionally | Review every high-impact endpoint and encode the approved role matrix | Implemented on branch; review and `main` verification pending |
| G0-21 | Spike email/OCR intake does not block stored row validation errors and its week-level overtime evidence is not bound to the confirmed legal workweek | Invalid or semantically misaligned extracted hours can reach payroll after a warning acknowledgement | Block validation errors; require confirmed, supported workweek evidence; reconcile extracted and overridden totals before apply | Code closed in PR #129; `main` green |
| G0-22 | Cornerstone Tax and AIRE frontend dependency audits report direct and transitive vulnerabilities, including critical/high findings | A companion application can remain an insecure production dependency even while Payroll itself is green | Upgrade to audit-clean compatible dependency sets; run each app's complete frontend/runtime gate; retain current-head review and post-merge evidence | Code closed in Cornerstone Tax PR #53 and AIRE PR #75; both production frontends verified |
| G0-23 | Creating annual company YTD state with a create-first helper conflicts with model uniqueness validation | A second committed pay period for the same company and year fails after the first created the annual aggregate | Reuse an existing annual aggregate, preserve the race-safe create path, and commit two sequential periods in regression and browser coverage | Code closed in PR #131; `main` green |

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
   - G0-21 follows as a separate payroll-intake boundary because it has a different evidence model and operator flow.
5. **Client portal data and approval boundary**
   - G0-14 and G0-15.
6. **Cornerstone Tax fail-closed authentication**
   - G0-16 and the Cornerstone Tax portion of G0-22 in the Cornerstone Tax repository.
   - Close the AIRE portion of G0-22 in its own repository before calling the companion boundary secure.
7. **Deterministic browser and production-shaped verification**
   - G0-17, G0-18, and the G0-23 defect exposed by the new release lane.
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

## External time destination contract

Time-source settings are secret-bearing integration configuration. Organization administrators may create, update, test, or deactivate them. Other staff may read only the non-secret metadata needed to select an already-approved source during payroll import.

In production, every source must use HTTPS on port 443 and its exact normalized hostname must appear in `TIME_TRACKING_ALLOWED_HOSTS`. At request time Payroll resolves the hostname, rejects the full DNS answer set if any address is loopback, private, link-local, shared-address, documentation, multicast, or reserved space, and pins the connection to one of the inspected public addresses. This closes the validation-to-connection DNS-rebinding window while retaining hostname-based TLS verification. Redirects are not followed, environment proxy variables are ignored, responses must be JSON and no larger than one MiB, and operator-facing errors never include the upstream response body.

Development may deliberately use `localhost` over HTTP for local integration testing. That exception does not exist in production. Production readiness fails when an active source exists without a hostname allowlist.

DNS resolution and every inspected-address TCP/TLS attempt share one monotonic five-second connection-establishment deadline. Payroll tries another inspected address only when connection establishment fails. It never replays the authenticated export request after request processing begins.

## Time Summary v1 authority and reconciliation contract

The normative payload and versioning rules are in [Time Summary v1 contract](TIME_TRACKING_V1_CONTRACT.md). Payroll owns the confirmed legal workweek and paid regular/overtime split. Time sources own approved daily/category evidence. Payroll rejects unreconciled totals and ambiguous category allocation; it does not let a source-provided overtime split replace Payroll's calculation.

This contract governs the AIRE, Cornerstone Tax, and custom Time Summary pull path. The separate Spike email/OCR adapter does not emit dated daily evidence and is tracked independently as G0-21; closing G0-10 through G0-12 must not be read as certifying that adapter.

## Client employee data and approval contract

Client employee access follows least disclosure. A stored full SSN is never serialized to a client. The employee form receives last four only and treats a blank SSN field as “keep the saved value.” A replacement requires entry and confirmation of the full value. Client request history redacts identifiers entirely; the staff review queue shows only masked original and proposed values. Full replacement identifiers exist only in the encrypted request payload and are decrypted for the locked approval transaction.

Basic profile changes—name, email, birth and hire dates, department, address, and phone—may apply immediately. Changes that affect pay, tax, classification, withholding, retirement, recurring earnings or deductions, wage rates, SSN, contractor EIN, or W-9 state create a pending staff review. If a mixed submission cannot create its review request, its direct-safe edits roll back as part of the same transaction.

A new worker submitted by a client is not payroll-ready before approval. The saved shell is inactive, has zero pay, carries `portal_pending_approval`, and is excluded from the normal active-worker list. Approval applies the encrypted and payroll-sensitive values, activates the worker, and clears the marker. Rejection leaves the shell inactive for staff follow-up; it does not silently activate or delete it.

Only one pending request may exist for a worker. Approval locks both request and employee, rechecks captured source values, and rejects a stale request rather than overwriting an intervening staff edit. A legacy request that contains a plaintext identifier without the corresponding encrypted payload fails closed and must be resubmitted.

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

The executable lane and its local/CI commands are documented in [Deterministic payroll release lane](DETERMINISTIC_RELEASE_LANE.md). It uses a disposable test database, synthetic identities that are unavailable outside explicit Rails test mode, and a separate CI job with no retries. The backend import corpus generates deidentified Revel-shaped PDFs at runtime and exercises the actual PDF reader rather than mocking extracted text.

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
| G0-07, G0-08, G0-13 | #126 | `b915fa3` | Yes | `main` Quality run 32618765810 passed | Greptile 5/5 on head `7ac5387`; deterministic PostgreSQL races cover lifecycle, check-number, YTD, and loan lock order |
| G0-09 | #127 | `d7db0b8` | Yes | `main` Quality run 32621927046 passed | Greptile 5/5 on head `76f7a42`; DNS, connection fallback, and all request attempts share bounded trust rules without replaying the export request |
| G0-10–G0-12 | #128 | `3b9a822` | Yes | `main` Quality run 32625636302 passed | Greptile 5/5 on head `24fbc29`; AIRE PR #74 (`f5186ad`) and Cornerstone Tax PR #52 (`ea7edc1`) emit complete Time Summary v1 day coverage before Payroll enforces it |
| G0-21 | #129 | `ad76491` | Yes | `main` Quality run 32627924118 passed | Greptile 5/5 on head `ac9f24d`; invalid rows, unsupported workweeks, and unreconciled override totals block apply |
| G0-14, G0-15 | #130 | `42d5784` | Yes | `main` Quality run 32631558131 passed | Greptile 5/5 on head `2f6a0e1`; client identifiers are masked and payroll-sensitive changes require locked staff approval |
| G0-16, Cornerstone Tax portion of G0-22 | Cornerstone Tax #53 | `ac01691` | Yes | Production signed-out admin and portal routes redirected to Clerk after merge | Greptile 5/5 on head `a583c80`; frontend dependency audit closed and production auth fails closed |
| AIRE portion of G0-22 | AIRE #75 | `b6321e2` | Yes | Production served the final reviewed asset set; authenticated dashboard and time-tracking surfaces loaded without mutation | Greptile 5/5 on head `4d6b24a`; dependency audit closed and public phone-link regression retained |
| G0-17, G0-18, G0-23 | #131 | `2d849b9` | Yes | `main` Quality run 32637076159 passed | Greptile 5/5 on head `fe607e7`; required `browser` check added to strict ruleset 16468532 |
