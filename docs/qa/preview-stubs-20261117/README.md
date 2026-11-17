# Preview statement selection QA

Scope: affected-flow QA executed by the implementation agent, November 17, 2026. Implementation tested at `ecf70620` plus the filename-only follow-up and documented scope regressions; base `30ed5ea6`; isolated branch `fix/preview-stubs-not-paper-check`.

Sources: the task's `BRIEF_COMMON.md` and `BRIEF_PREVIEW_STUBS.md`, `PayrollPreviewPdf`, `PayStubsController`, `ChecksPanel`, `ClientPayrollReview`, and `ReportsController#full_print_package_pdf`. Cornerstone staff prepare payroll and share previews before commitment. Paper checks with positive net should appear once in combined previews; separate stubs default to direct deposits and statement-only activity. The run's effective payment method controls membership. All statements remain explicitly available. Printing, numbering, issuance and payment logic are outside this change.

Full Print Package contains a transmittal, payroll summary, deductions/contributions, paycheck history, retirement and installment-loan reports. It contains no individual earnings statements or checks, so its contents do not change.

Fixture: copy of synthetic `cp_demo_video_base_20261117`, company 6 Hale's Grill & Bar. Run 118 is cloned from synthetic run 117 into Nov 2–15, paid Nov 19, with a controlled mix of 9 paper checks, 42 positive-net direct deposits and 1 zero-net statement-only item. No source demo, shared or production database is changed. Cloned standalone loan inputs are cleared. Approval/commit fixture states are set locally to exercise download surfaces; the automated regression exercises the real lifecycle endpoints. This QA does not revalidate importing or calculation totals.

Required scenarios (agent executes through the real local UI):

| ID | Journey and expected result | Desktop 1280×800 | Mobile 390×844 |
| --- | --- | --- | --- |
| P1 | Download all four preview options. Combined 9 checks + 43 stubs; checks 9; stubs 43 with no positive paper-check employee; all stubs 52. Alphabetical within each part, audit part correct, no check-number allocation. | Passed | Passed |
| P2 | Committed run: default non-check download excludes positive paper checks and retains zero-net statements; all download includes all activity. Selected paper-check employee remains printable. | Passed | Passed |
| P3 | Preview error remains recoverable and retry succeeds, preserving run context. | Passed | Passed |

P1 evidence: [saved staff PDF checks](staff-pdf-results.json). Downloaded all four options at both dimensions. PDF text extraction matched the complete expected employee list and order. Combined: 9 checks + 43 statements (56 pages); checks: 9 people/pages; stubs: 43 people (47 pages); all stubs: 52 people (56 pages). Four long statements paginate. Staff audit counts were combined 2, checks 4 (including two successful retries), stubs 2 and all_stubs 2. Numbered items remained zero.

P2 evidence: each dimension downloaded non-check statements (43 people), all statements (52) and selected paper-check employee (1), then cleared selection. Each downloaded PDF matched the expected complete employee list/order. The fixture’s paper checks are unnumbered; this QA verifies statement downloads, not check preparation.

P3 evidence: injected one local 503 response at the preview fetch boundary on each dimension. The UI showed “Preview temporarily unavailable. Try again.”, kept the same run URL, enabled retry and completed the retry download. These failures were simulated; successful retries used the real API. Mobile document width equaled 390px with no horizontal overflow.

P4 — Client portal: combined/default preview and explicit all-stub download, desktop and mobile; passed at both dimensions: each combined PDF matched 9 checks + 43 statements, each all-stub PDF matched all 52 employees in order. See [portal PDF results](portal-pdf-results.json). Mobile all-stub label fits and document width remains 390px. The isolated demo company has client review enabled, a synthetic active client and a published review revision; all notifications are local with outbound keys blanked.

Screenshots: [desktop preview menu](desktop-menu.png), [mobile preview menu](mobile-menu.png), [mobile committed actions](mobile-committed.png), [mobile portal](mobile-portal.png), [desktop portal](desktop-portal.png).

Automated acceptance: mixed-method service parts and per-run overrides; staff/client request filtering and audit metadata; real calculate → approve → preview → unapprove → change hours/recalculate → approve → preview with changed PDF amounts and increasing filename revision.

Limits: responsive browser dimensions, not physical mobile hardware or native printing. No checks issued, payments sent, production access, merge or deployment.

Review scope decisions: CodeRabbit initial review of `ecf70620` requested automatic inclusion of First Hawaiian 4-Up and retained-wage voided paper checks. Both would expand the specified delivery-method default. The implementation keeps the brief’s default and explicit all/selected access; the runbook now documents these exceptions, with added regression coverage. The review reply records the rationale. CodeRabbit withdrew both suggested default changes after the scope explanation and requested pushed evidence for the documented exceptions and added tests. The original review state remains changes requested until it is updated.

Engineering gate: relevant RSpec; RuboCop on changed Ruby files; Brakeman; frontend lint, TypeScript and 52 affected Vitest tests; Impeccable advisory scan (no findings). Full RSpec is delegated to CI because of its normal ~20-minute duration. 74 relevant RSpec examples passed; a subsequent affected-spec run passed all 29 examples, including the two added scope regressions (76 unique relevant examples total). RuboCop and Brakeman passed after the filename changes. All task-owned servers and browser resources were cleaned; both isolated databases, the copied .env and disposable frontend dependencies were removed after the last test run. Raw downloads are temporary browser artifacts; the membership results and screenshots are retained here.
