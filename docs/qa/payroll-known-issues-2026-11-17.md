# Payroll commit confirmation and Payroll files links

Implementation worker: GPT-6.1 Sol. Base `origin/main` at `7ae3a77b`; branch `fix/payroll-known-issues`, worktree `worktrees/cp-known-issues`. PR is held for the lead; no production access, merge or deployment.

Cornerstone staff import client files, calculate, approve and commit payroll. Commit locks financial results and assigns check numbers. A client file request remains outstanding until accepted or withdrawn; staff may commit after acknowledging the exact requests they reviewed. Paper checks and direct deposit retain separate issuance/settlement steps. Payroll files must stay associated with the selected run when dates change or multiple runs share dates.

Sources: `BRIEF_COMMON.md` and `BRIEF_KNOWN_ISSUES.md` in `output/mosa-payroll-workflow-20261116`, PR #475 diff and merge record, `PayPeriodLifecycleService`, `PayrollSubmissions::Catalog`, `PayrollSubmissionPeriod`, and `PayrollCommitDialog`. Historical business context: Brain Dump `work/shimizu-tech/Cornerstone/payroll-priorities-and-aire-reconciliation-2026-09-19.md` (staff roles, checks versus stubs and saved financial evidence). The November brief governs current scope; historical notes do not establish current production acceptance.

## Acceptance plan

Agent executes affected-flow QA with synthetic fixtures in `cp_dev_known_issues`. Automated tests use only `cp_test_known_issues`. Both databases were absent before this task. Email transport is disabled. Existing shared Postgres/Redis and all other baseline resources are borrowed.

| Case | Starting conditions and actions | Expected visible and saved outcome | Desktop 1280px | Mobile 390px |
| --- | --- | --- | --- | --- |
| K1 | Open approved run from run page and list; acknowledge named requests; commit | Fresh counter, exact request IDs sent; committed run and audit retain IDs; requests stay outstanding | passed | passed |
| K2 | Open dialog, add or resolve a request, confirm old snapshot | 409; no financial effects; dialog reloads list, clears acknowledgement, asks again; second confirmation succeeds | passed | passed |
| K3 | Open dialog, advance company check counter, confirm old number | 409; no financial effects; dialog shows new number; second confirmation assigns that number | passed | passed |
| K4 | Create files period before/after run; backfill legacy rows; exercise ambiguous dates | Unique matches link explicitly; repeat backfill preserves links; ambiguity surfaces to staff and blocks commit until explicit selection | automated | automated |

Required local gate: relevant RSpec, changed-file RuboCop, Brakeman, frontend lint, TypeScript, affected Vitest. Browser dimensions cover pointer interactions, scrolling, visible recovery and saved results. Physical-device/PWA, printers, real email, bank settlement and production are outside scope.

## Execution record

All three browser cases passed from both the run page and list page at 1280×800 and 390×844: twelve synthetic runs committed, each with one commit audit, gross $1,200 and net $1,100. Request conflicts covered new requests at both widths and a resolved request from the mobile list. Rejected attempts retained approved state and unassigned checks. A counter advance returned 409, refreshed the displayed number and cleared acknowledgement; the second confirmation assigned that exact number. Request IDs in successful payloads match saved audit IDs; outstanding requests remain outstanding. Resolving the last request refreshes to an empty list and still requires the second explicit confirmation.

Browser checks used real Rails test-mode responses and persisted synthetic records, with no mocked API results. Concurrent request creation/resolution and counter updates were fixture actions through the real API while the dialog stayed open; the commit journey itself used the interface. List-row clicks used DOM controls after two preview-selector errors; the alternate browser connector was unavailable (`native pipe closed before response`). No horizontal page overflow was observed. Dialog scrolling reached acknowledgements and confirm/cancel controls at both widths. Physical-phone/PWA and financial settlement remain outside scope.

[Saved outcomes](payroll-known-issues-2026-11-17/saved-outcomes.json) verify the twelve commits, check numbers, retained requests and audit metadata. [Browser traces](payroll-known-issues-2026-11-17/browser-traces.json) record the list and mobile request payloads, 409 codes and recovered 200 responses. Repeated instrumentation wrappers initially duplicated captured entries on the desktop list; the artifact deduplicates identical captures. Saved audit counts independently verify one commit per run. Desktop run checks 1–3 were verified through the browser and persisted evidence before instrumentation was added.

Visual evidence: [desktop changed requests](payroll-known-issues-2026-11-17/desktop-requests-conflict.png), [desktop counter](payroll-known-issues-2026-11-17/desktop-counter-conflict.png), [mobile changed requests](payroll-known-issues-2026-11-17/mobile-requests-conflict.png), [mobile resolved request](payroll-known-issues-2026-11-17/mobile-resolved-request.png), [mobile counter](payroll-known-issues-2026-11-17/mobile-counter-conflict.png). The trace artifact retains payloads and status codes; visual evidence is linked above. Screenshots preserve the operator's scroll position; the interaction traces and saved records establish recovery.

## Implementation and automated checks

Commit compares `acknowledged_outstanding_file_request_ids` to the exact live set under the company/run lock. File-request actions acquire the company lock as well, serializing creation and resolution with the comparison and financial effects. Both dialog entry points refresh the full run, list requests by name, submit the IDs and displayed `expected_next_check_number`, and reload only the two specific commit conflict codes. Generic errors stay in the dialog. Trusted service/API callers that do not provide a check-number expectation retain the previous behavior; browser commits always provide it for paper-check runs. The former boolean cannot acknowledge outstanding requests.

New periods/runs persist an unambiguous explicit link under the company lock. Importing an explicitly selected matching regular run can claim an ambiguous unlinked files period. Existing active links remain authoritative after date edits or duplicate creation; creation of a unique replacement can explicitly reassign a voided run's period, preserving the existing source-correction journey. The SQL-only, idempotent migration links only unlinked rows with exactly one eligible same-company run. It works on an empty database, preserves existing links and skips ambiguous/missing/voided/supplemental matches. Catalog date fallback returns only a unique match; staff see ambiguous IDs and unresolved ambiguous file requests block commit.

Validation: a 259-example broad RSpec batch and a 35-example final backend retest passed; the separate portal-import request suite passed all 119 examples; all 1,930 Vitest tests across 196 files passed (including 180 affected tests); frontend lint, TypeScript (`tsc -b` and `tsc --noEmit`) and changed-file RuboCop passed. Brakeman reports zero errors/warnings. Advisory Impeccable reports no findings. The final retests include the additional eligibility fixture, locked counter comparison, batched catalog candidates and company-switch dialog reset. Full RSpec is left to CI; no full application or release certification is claimed.

Retest trail: a new resolved-request fixture initially omitted required resolution metadata; fixed. The broad run caught a voided-run source-correction regression; explicit replacement linking restored it, and the 259-example rerun passed. Parent-page Vitest fixtures were updated for the required fresh GET and errors retained inside the dialog. The portal-import suite initially retained the old automatic date-choice assertion; the updated request test verifies that explicit selection resolves ambiguity and supplemental runs remain refused. All 119 import examples passed on rerun.

Owned Rails/Vite processes and browser tab were cleaned after browser QA using lifecycle session `01a1e657-ef09-7f61-9a8f-3830f0f4cfb8`; the helper reports no active owned resources. Isolated database cleanup and final PR/review state are recorded in the handoff.


## PR review status

PR #478 is held for the lead. CodeRabbit's automatic review was rate-limited at 2026-11-16 22:19:50 UTC; it reported the next included review in 40 minutes. No CodeRabbit review or inline findings exist yet. Its success-labelled check is a skipped review, not approval. No independent reviewer was started because the worker brief forbids subagents. Required backend/frontend/browser CI remains a separate gate. The lead can request `@coderabbitai review` after the limit resets; no merge or deployment is authorized for this worker.


## Main integration

After PR creation, main advanced to `2d4085ed` (#477), changing only the default development database name in `api/config/database.yml` to `cornerstone_payroll_development`. This branch merges that commit. Explicit test and development overrides were verified through Rails configuration without opening database connections: `cp_test_known_issues` and `cp_dev_known_issues` remain selected. No product code or test database configuration changed; the earlier isolated test and browser evidence therefore exercises the same product paths. Both owned databases remain dropped, with no new runtime resources. Final-head CI must assess the merged tree.
