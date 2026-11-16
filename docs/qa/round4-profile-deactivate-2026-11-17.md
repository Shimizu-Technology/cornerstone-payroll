# Profile deactivation round 4 — lead handoff

Ready for independent re-review; do not merge or deploy. Worktree: /Users/agent/work/worktrees/cp-b7b-deactivate; branch: feat/profile-deactivate; PR: https://github.com/Shimizu-Technology/cornerstone-payroll/pull/469. Started from f6fc4f134651ad27cf02be5d33476f5ab01b535d; git pull and merge origin/main both reported already up to date (main 80ed984b). No production access.

App context is inherited from the round-3 QA brief and refreshed against the transition service, employee serializer, eligibility projection, removal controller, dialog and payroll gate panel. Payroll staff must preserve final hours on partial-period runs while resolving workers who are ineligible for later regular runs.

Changes:
- EmployeeStatusTransitionService.open_run_groups is the server source for remove/check groups. Runs starting on/after the effective date are in Remove; runs starting before and ending on/after it are in Check. Only approved Remove runs block status changes. Both groups remain restricted to open regular runs containing the worker.
- Dialog uses the server action classification, shows removal and partial-period recalculation guidance separately, and ignores approved Check runs when deciding whether to enable submission.
- PayrollItem.status_removal_resolution supplies the same AIRE/tax evidence guidance to the removal response and eligibility panel. Removal returns 422 before changing retained AIRE allocations or FICA proof; DeleteRestrictionError is rescued as well. No allocation release was added.

Agent-executed affected-flow acceptance:
1. PASS: Nov 20 termination/deactivation with Nov 16–30 calculated or approved run: server lists Check, status saves, eligibility gate remains clear, paycheck retained. Service regression specs freeze Nov 21.
2. PASS: Runs starting on/after effective date stay in Remove. Approved runs still block; draft/calculated runs remain actionable. Employee GET tests verify server action classification; dialog tests verify both groups and blocking behavior.
3. PASS: AIRE entry allocation and FICA proof each produce an actionable removal 422, preserve paycheck/evidence, create no exclusion, and expose the same guidance in the eligibility payload.
4. PASS: Chromium component harness with both groups and an approved Check run at 1280x800 and 390x844: readable groups/links, enabled submit, successful synthetic submission callback, scrollable form, no page/dialog horizontal overflow. Real dialog; synthetic API responses. Browser fixture uses Nov 17 within Nov 1–30 because Nov 20 is future on this host; exact Nov 20 / Nov 16–30 case is covered in service and Vitest tests.

Validation:
- Targeted RSpec: 181 examples, zero failures (transition service, run eligibility, payroll items requests, employee requests, employee eligibility, run-payroll requests, bounded pay-period detail reads). After final rescue consolidation/method placement, payroll-items requests rerun: 56 examples, zero failures.
- Full Vitest: 190 files / 1,863 tests passed, maxWorkers=2. Final focused dialog run: 7 tests passed.
- ESLint and tsc -b passed after temporary harness removal. Full RuboCop: 1,857 files, no offenses. Impeccable advisory: [].
- Initial RSpec run preceded updated boundary expectations and failed two old covering-run assertions; updated start-date fixtures pass. Initial lint/type checks included the temporary harness and flagged harness-only issues; final clean-tree checks pass.

Limits: Full authenticated payroll end-to-end and Safari/real mobile were not run. No deployment/release verification was attempted. Final-head CI and independent round-4 review remain for the lead; no review-clean claim.

Resources: temporary harness removed; Vite PID 56660 stopped; both owned preview tabs closed. Lifecycle session manual-20261117-011759-56081-04ed has no unresolved resources. cp_test_b7b dropped; protected shared PostgreSQL left running. Worktree/branch retained. No runtime resource handoff.

Next: verify pushed head/clean status, inspect CI and independently re-review the narrow round-4 diff. Continue to hold merge/deployment.
