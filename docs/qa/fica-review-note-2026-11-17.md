# FICA review-note correction — B2

## Context and acceptance

Implementation base: `origin/main` at `1ad7656a7419cd92096661c8a53a0c575350e592`. Sources: the lead's November 16 task brief, `docs/FICA_LEGACY_RECOVERY.md`, `BelowThresholdFicaContext`, `EmployeeYearFicaContext`, `PayPeriod#annual_fica_review_note`, and the existing FICA and pay-run tests. Production state comes from the lead's brief; this worker made no production connection.

Cornerstone staff calculate, review, approve, and commit client payroll. A verified-empty historical row already excluded from the annual ledger must not create a review obligation. Actual financial reversals and voided periods retain their eligibility and conservative proof requirements. Imported history can justify the fallback only when the ordinary calculation failed; it must not create a warning on a successful ordinary calculation. Employee/employer Social Security and Medicare, Additional Medicare, saved wages, and committed history must remain unchanged.

Required acceptance: reproduce the empty-disposition/source-review/later-paycheck shape; clear its false note after rolling back approval and recalculating; retain specific notices for genuine history; show affected worker names; preserve older snapshots; pass the relevant local gates.

## Change and snapshot flow

- `BelowThresholdFicaContext#unresolved_history?` disregards `verified_empty_legacy_item` as a dispute. A separate financial reversal or period void still counts. Disposed rows remain in conservative bounds and source digests when another genuine dispute requires that path.
- `EmployeeYearFicaContext#increment` returns the verified ordinary calculation when it succeeds. It retains an optional below-threshold snapshot only for genuinely unresolved native history and only when the proof's amounts equal the ordinary amounts. A failed ordinary calculation still uses the existing guarded fallback.
- `tax_rule_snapshot["annual_fica_context"]` retains its version, keys, and types. Newly calculated `note` text names the real reason: reversed paycheck IDs, voided pay-period IDs, or imported history. The existing open-review flags remain true when that path is used.
- `PayPeriod#annual_fica_review_note` aggregates only financially reportable items with `history_review_open == true`, prefixes their stored notes with worker names, and feeds both the dedicated API field and `compliance_warnings`. It loads employee names only for those rows, preserving the no-warning query budget.
- `FicaHistoryReviewNotice` already renders the API string, and `PayRunBlockers` already suppresses its duplicate compliance warning. Frontend production code needs no change. Vitest covers names, actual reasons, approval visibility, deduplication, and legacy text.
- Older committed notes are displayed as stored, with a worker name. A missing note uses the legacy text. No historical rows or snapshots are rewritten; unfinished runs need rollback of approval, recalculation, review, and reapproval.

## Amounts-unchanged evidence

The new request regression failed against the original code because `history_review_open` remained present after adding the empty disposition and source review. Its FICA equality assertion already passed. With the fix, the same regression passes: before/after values for employee SS, employer SS, employee Medicare, employer Medicare, and Additional Medicare are identical. For the $500 fixture they remain $31.00, $31.00, $7.25, $7.25, and $0.00.

The approved-run regression preserves those same components through unapprove, recalculate, approve, and commit. The empty-history regression also verifies that the saved historical row is unchanged. Separate reversal and void regressions compare all five tax components and all four FICA wage bases against an undisputed ordinary paycheck and again after commit. Existing threshold, signed-correction, imported-proof, stale-evidence, and annual-ledger tests retain their numeric expectations.

## Execution ledger

All fixtures are synthetic. Agent executed on the Mac mini, Ruby 3.3.7, Node 22.22.3, local PostgreSQL 16, isolated database `cp_test_b2_fica`. No secrets, external payroll sources, or real financial transactions were used.

| Scenario | Execution | Result |
| --- | --- | --- |
| Empty committed row + verified-empty disposition + zero-bound source review + later regular paycheck | Rails request; API payload, saved snapshot, tax components, historical row | Passed |
| Existing approved run with legacy false note; unapprove, recalculate, approve, commit | Rails request; saved status and all FICA components | Passed |
| Genuine reversal and genuine void with verified ordinary annual path | Service/lifecycle; specific note, bases/taxes before/after and commit | Passed |
| Void/replacement requiring the fallback | Existing service and request journeys; API warnings, commit, saved amounts | Passed |
| Imported proof path | Existing reconciliation/lifecycle specs; imported-only reason and named notice | Passed |
| Multiple affected workers; unaffected worker excluded | Model exercised in request spec; warnings and worker-specific reasons | Passed |
| Older committed note and missing-note fallback | Request/model and Vitest; stored text preserved with worker name | Passed |
| Notice at approval; no duplicate warning; no unrelated settings link | Vitest | Passed |
| Specific multi-worker text, no horizontal overflow, absent note hidden, legacy note readable | Actual notice component with compiled app styles in headless Chromium via Playwright 1.61.1; 1280 × 900 and 390 × 900 | Passed |
| Full authenticated browser payroll journey, WebKit/mobile Safari, native device behavior | Not executed locally; component browser checks and Rails requests are separate evidence | Not run |

The first broad local run found one query-budget failure (66 queries, limit 65). Employee preloading was narrowed to open-note rows; the affected query-count and FICA rerun passed (91 examples). The first browser harness attempt blocked an external font import and failed to inject its stylesheet; rerunning with that import omitted passed at both widths. These are recorded as failures followed by successful retests, not production defects.

Round-1 local gate (superseded for final-head readiness by the round-2 results below): **522 RSpec examples passed**, **1,849 Vitest tests passed across 188 files**, web lint and `npx tsc -b` passed, RuboCop passed on all seven changed Ruby files, and `git diff --check` passed. The broad RSpec command was:

```sh
RAILS_ENV=test TEST_DATABASE_URL=postgres://localhost:5432/cp_test_b2_fica bundle exec rspec spec/services/*fica*spec.rb spec/services/payroll_calculator*spec.rb spec/services/pay_period*spec.rb spec/models/pay_period*spec.rb spec/requests/fica*spec.rb spec/requests/pay_period*spec.rb spec/requests/api/v1/admin/pay_period*spec.rb spec/requests/api/v1/client/pay_periods_spec.rb
```

The tested source is the implementation committed with this record; the final SHA is recorded in the PR. The full Rails suite and required `backend`, `frontend`, and `browser` checks run in CI. Required checks and CodeRabbit status must be assessed against the final PR head before integration.

## Round 2 — reconciled imports on the ordinary annual path

The lead's read-only production findings showed that the nine affected workers also have 11–17 imported 2026 checks each, with matching reviewed proofs and source reviews. Round 1 still treated the presence of those imports as a reason to replace a successful ordinary snapshot. This worker used the supplied findings and synthetic fixtures only; no production access occurred.

Implementation started from `7fe37e3b9216e028aaec1e89c3e8f8c89b6622df` in the same isolated worktree. `unresolved_history?` now gates the optional snapshot after ordinary success. The rescue branch retains `applicable?`, so imported history can still enable the guarded fallback. Optional snapshots exclude imported history from their reasons. Approval, commit and client review recompute whether the ordinary path succeeds to regenerate the same note, retaining the snapshot's existing shape. Imports remain in the conservative bounds, proof verification and source digest whenever a bound snapshot is used.

The applied-opening and imported-paycheck builders were moved unchanged from the existing recovery/reconciliation specs into `spec/support/fica_history_helpers.rb` and reused by the new request regression. It creates an applied bridge/opening balance, 11 imported checks, 11 matching proofs through the real reconciliation service, a source review, a committed $0 verified-empty item, and a new $500 regular check. It compares all five tax components and all four wage bases to the ordinary calculation, checks the API and saved snapshot, and approves/commits the run. The historical rows remain unchanged. The conservative proof is independently available, reproducing why round 1 attached the false warning.

| Required round-2 scenario | Evidence | Result |
| --- | --- | --- |
| Applied bridge + 11 reviewed imports + source review + verified-empty item; calculate, approve, commit | Request regression: no open-review flag or period note, all FICA amounts/bases equal ordinary, history unchanged | Passed |
| Reproduce false warning against round-1 services | Same request regression, with services temporarily restored to `7fe37e3b`; equality passed, then absence of `history_review_open` failed | Expected failure reproduced |
| Genuine reversal and void without imports | Existing specific-note and saved-amount lifecycle regressions | Passed |
| Genuine reversal and void with reviewed imports; ordinary path succeeds | New service regressions: only the native reason appears; all ordinary components/bases survive approval and commit | Passed |
| Ordinary path fails, imports enable fallback | New regression explicitly proves ordinary failure and `unresolved_history? == false`; named imported-history note persists through commit | Passed |
| Nine-worker rounding fixture | Updated expectation distinguishes the worker needing the fallback from eight workers with a successful ordinary calculation | Passed |

The initial local database preparation loaded operational tax seeds, which collided with spec factories. Reloading the schema without seeds matched CI and resolved the fixture setup. The focused run then found an obsolete nine-worker expectation that every reconciled worker must retain a warning. That expectation was corrected according to the demonstrated calculation paths. RuboCop also found one extra blank line in the extracted helper, which was removed.

Round-2 local validation: **526 RSpec examples passed** using the targeted command recorded above; **1,849 Vitest tests passed across 188 files**; web ESLint and TypeScript checks passed; **RuboCop inspected all 1,847 Ruby files with no offenses**; and `git diff --check` passed. The web gate's build initially stopped because deployment flags were omitted; rerunning `DEPLOYMENT_ENV=production VITE_DEPLOYMENT_ENV=production npm run build` passed (local compilation only, no deployment). Its existing large-chunk advisory remains nonblocking.

Cleanup: `cp_test_b2_fica` was dropped and its absence verified. The protected shared PostgreSQL server remains available. Lifecycle session `manual-20261117-000835-41027-d523` reports no active owned resources. No server or browser was started in round 2. The worktree and branch remain for the lead. The shared-context check could not run because `/Users/agent/.config/shimizu-technology/agent-context.json` is absent; the synced applicable guidance was read directly.

The tested implementation is committed with this record; the PR records its exact SHA and the latest CI/CodeRabbit state. Round-1 CodeRabbit approval does not establish review of round-2 changes.

The full authenticated browser payroll journey and Safari/device coverage are not rerun in this round; the change is in backend path selection and note generation, exercised through Rails request/lifecycle specs and the existing web test gate. Round-1 browser component evidence remains recorded separately above.

## Lead handoff

Branch: `fix/fica-review-note`. Worktree: `/Users/agent/work/worktrees/cp-b2-fica`; keep it in place. The worker must not merge or deploy. Integration and release belong to the lead. No migration or data repair is needed. Recalculate affected unfinished runs through the normal workflow after release; committed historical notes are intentionally preserved.

The head SHA, PR URL, current CI/CodeRabbit status, any residual findings, and verified cleanup are returned with the handoff. No local server or browser is intentionally handed off. Shared PostgreSQL is borrowed/protected; only the task's database is dropped.
