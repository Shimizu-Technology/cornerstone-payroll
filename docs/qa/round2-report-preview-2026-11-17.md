# Precommit report preview round 2

Product context: Cornerstone staff review Guam payroll before approval/commit and issue checks separately (README.md). Preview exports must remain distinguishable from committed payroll. This follow-up addresses PR #471 review findings against origin/main 1d64bd46, including #467. No production access, merge, or deploy.

All three CI failures were reproduced together (22 examples, 3 failures): bounded detail read used 67 queries against a limit of 65; rehearsal CSV started with PREVIEW instead of Payroll Status; the preview stamp bypassed PdfUnicodeFont. The same 22 examples passed after the fixes without changing the query threshold.

Implementation:
- Check-number history is computed only for approved, non-list responses. The maximum also includes replaced_check_number.
- All uncommitted native report downloads, including stale draft calculations, are labelled. Every workbook sheet receives its own first header row, with merged-cell references shifted. Check signoff's custom generator has the same header.
- Test workspaces retain their existing rehearsal labelling without the additional PREVIEW overlay. This preserves the Payroll Status row and keeps their dedicated TEST ONLY explanation authoritative.
- PDF overlays use PdfUnicodeFont and cache one stamp per page size per export.
- Check settings permission follows the selected company's capability plus write access. Commit confirmation warns when the next number is at/below the maximum and hides numbering for runs without paper checks.

Validation: 535 RSpec examples passed across report request/service specs, the three CI regressions, detail reads, check-number requests, status service/model coverage, and spreadsheet exports. Added export tests cover draft/calculated/approved summary workbooks and signoff sheets. Vitest: 188 files, 1851 tests passed with maxWorkers=2. An earlier concurrent run hit the unrelated document-pagination timeout; its isolated rerun passed all 8 tests. ESLint and tsc -b passed. RuboCop: 1848 files, no offenses. Brakeman: no warnings. Impeccable advisory returned [].

Agent-executed Chromium component QA used a temporary synthetic fixture and the real commit dialog at 1280x800 and 390x844: next 1001 versus last 5000 produced the requested warning, check-settings href was correct, no horizontal overflow, cancellation closed without confirming. Backend and component tests verify the data and bank-only case. Full authenticated end-to-end payroll was not run. Safari/WebKit was not run on this headless Mac mini.

Temporary harness, Vite server, and owned tab were removed/stopped/closed. Test database cp_test_b5 is dropped at handback. Existing worktree and branch are retained for the lead; no runtime handoff.
