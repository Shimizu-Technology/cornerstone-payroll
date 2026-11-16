# FICA review-note correction — B2

## Context and acceptance

Implementation base: `origin/main` at `1ad7656a7419cd92096661c8a53a0c575350e592`. Sources: the lead's November 16 task brief, `docs/FICA_LEGACY_RECOVERY.md`, `BelowThresholdFicaContext`, `EmployeeYearFicaContext`, `PayPeriod#annual_fica_review_note`, and the existing FICA and pay-run tests. Production state comes from the lead's brief; this worker made no production connection.

Cornerstone staff calculate, review, approve, and commit client payroll. A verified-empty historical row already excluded from the annual ledger must not create a review obligation. Actual financial reversals, voided periods, and imported history retain their eligibility and conservative proof requirements. Employee/employer Social Security and Medicare, Additional Medicare, saved wages, and committed history must remain unchanged.

Required acceptance: reproduce the empty-disposition/source-review/later-paycheck shape; clear its false note after rolling back approval and recalculating; retain specific notices for genuine history; show affected worker names; preserve older snapshots; pass the relevant local gates.

## Change and snapshot flow

- Both `BelowThresholdFicaContext#applicable?` and `#disputed_history?` disregard `verified_empty_legacy_item` as a dispute. A separate financial reversal or period void still counts. Disposed rows remain in conservative bounds and source digests when another genuine dispute requires that path.
- `EmployeeYearFicaContext#increment` returns the verified ordinary calculation when it succeeds. It retains an optional below-threshold snapshot only for genuine disputed/imported history and only when the proof's amounts equal the ordinary amounts. A failed ordinary calculation still uses the existing guarded fallback.
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

Final local gate: **522 RSpec examples passed**, **1,849 Vitest tests passed across 188 files**, web lint and `npx tsc -b` passed, RuboCop passed on all seven changed Ruby files, and `git diff --check` passed. The broad RSpec command was:

```sh
RAILS_ENV=test TEST_DATABASE_URL=postgres://localhost:5432/cp_test_b2_fica bundle exec rspec spec/services/*fica*spec.rb spec/services/payroll_calculator*spec.rb spec/services/pay_period*spec.rb spec/models/pay_period*spec.rb spec/requests/fica*spec.rb spec/requests/pay_period*spec.rb spec/requests/api/v1/admin/pay_period*spec.rb spec/requests/api/v1/client/pay_periods_spec.rb
```

The tested source is the implementation committed with this record; the final SHA is recorded in the PR. The full Rails suite and required `backend`, `frontend`, and `browser` checks run in CI. Required checks and CodeRabbit status must be assessed against the final PR head before integration.

## Lead handoff

Branch: `fix/fica-review-note`. Worktree: `/Users/agent/work/worktrees/cp-b2-fica`; keep it in place. The worker must not merge or deploy. Integration and release belong to the lead. No migration or data repair is needed. Recalculate affected unfinished runs through the normal workflow after release; committed historical notes are intentionally preserved.

The head SHA, PR URL, current CI/CodeRabbit status, any residual findings, and verified cleanup are returned with the handoff. No local server or browser is intentionally handed off. Shared PostgreSQL is borrowed/protected; only the task's database is dropped.
