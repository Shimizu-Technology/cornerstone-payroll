# Year-end filing record — implementation and acceptance

2026-11-20; branch `feature/year-end-filing-record`, based on main `50e5325b`.

Cornerstone staff prepare year-end files for Guam payroll clients, then upload them outside the app. The W-2 EFW2 file requires two independently confirmed submissions (SSA BSO and GuamTax); Pub 1220 requires GuamTax only. The research goal is generation, review, external upload and retained acceptance evidence (`W2GU_1099_YEAR_END_FILING_RESEARCH_2026-11-17.md`, §8 step 5). This change records staff-reported portal activity; it does not upload files or imply agency acceptance from a download.

## Storage and deployment

Annual identity now includes `agency`. Quarterly identities remain unchanged. Existing W-2 records, including prior years, become `legacy` (agency not recorded), retaining IDs, receipts, events and references. They remain readable in the agency panels and do not count as either agency's acceptance. Existing 1099 records become DRT records.

The migration does not rewrite append-only events. It adds a nullable download-audit foreign key and SHA256 to events and allows an optional receipt for annual events. Quarterly receipts remain required by the recorder and model. Rollback refuses with explicit counts when agency records or file-bound/receipt-free events would lose information. Preserve the schema when rolling back application code. Use a compatible rollback release that can read receipt-free annual events and preserve the separate W-2 agencies. Older serializers fail when reading events without receipts; stopping annual writes alone is insufficient. If a compatible release is unavailable, disable annual reads and annual writes until compatibility is restored.

Only final EFW2 and Pub 1220 download audit entries qualify as portal-upload files. PDF copies and transmittals do not. Submitted/resubmitted events retain the selected audit ID and SHA256. Selection is company/year/action/mode scoped and checked against the current filing-input fingerprint. Historical Pub 1220 audits lacking a fingerprint require a fresh download. Source changes after filing warn without blocking outcomes.

Preparation readiness, `SIGN_OFF_STEPS`, `ReadyCheck`, `EfileCheck`, counts and next-step selection are unchanged. Filing progress is a separate payload and the “File and confirm” card follows the preparation steps. The clients list batches filing records/download lookups. A deadline-period reminder counts clients with an unfiled or correction/retry-required agency submission.

The existing `manage_filing_review` capability remains required. Test workspaces are blocked. Each recorded event produces a domain audit, atomically with the event.

Requires the API migration and web build; a production frontend build is expected. No production access or deployment performed. PR #504 supplies the real 1099 sign-off. Before #504, final 1099 recording remains disabled; the integration detects its `Form1099FilingReadiness` / `Form1099InputsFingerprint` classes when available. Reconcile the reports-controller audit metadata line when integrating #504.

## Agent-executed acceptance

Factories only, isolated local Postgres databases. No real client records or portal submissions. Chromium at 390×844 and 1440×1000; no native phone, Safari or WebKit coverage.

| Required case | Result | Evidence |
| --- | --- | --- |
| Record SSA, independently record DRT | Passed at both widths | Real local Rails API, separate agency records |
| Accept SSA, reject DRT, resubmit DRT | Passed at both widths | SSA accepted with 2 events; DRT submitted with 3 events; verified in Postgres |
| Preserve agency outcomes on reload | Passed | Reloaded panels retained accepted SSA and submitted DRT with histories |
| Pending state, latest file selection, no horizontal overflow | Passed | Repeatable Playwright fictional-transport suite, 2 tests |
| Draft, wrong company/year, stale file refusal | Passed in automated service specs | `annual_filing_submissions_spec.rb` |
| Post-filing data change warning without blocking outcome | Passed in service/request specs | `payroll_filing_records_spec.rb` and recorder specs |
| Preparation parity after both agency records accepted | Passed in checklist/list spec | Same status, issue count, next step, steps and list counts |

Screenshots: `docs/evidence/filing-record/connected-390.png`, `connected-1440.png` (real local API); `lifecycle-390.png`, `lifecycle-1440.png` (repeatable fictional browser transport).

The connected browser fixture uses factory payroll/sign-off data and a synthetic final-download audit; it tests recording and persistence, not file generation or portal delivery. File generators have their existing test suites. Real agency acceptance of a client filing remains an operational milestone outside this change.

## Verification

Final backend rerun: `RAILS_ENV=test TEST_DATABASE_URL=postgres://localhost:5432/cp_test_filing_record bundle exec rspec` — **7,704 examples, 1 failure, 4 pending** (7,699 passed), in 13m15s. The sole failure is the unchanged converter-environment assertion described below. All task-related full-suite failures from the first run were fixed. The final one-line stale-file wording and added deadline reminder case are covered by the final affected-spec run: **127 examples, 0 failures**. This includes requests, agency lifecycle/file binding, migrations, models, checklist/list parity, query scaling and response-deadline checks.

`bundle exec rubocop` — **1,943 files, no offenses**. Frontend lint, both requested TypeScript commands, and the complete Vitest suite passed: **2,084 tests, 209 files** with two workers. The repeatable Chromium suite passed **2 tests**, one at each width. Initial full Vitest run had one employee-documents pagination timeout (2,083 passed, 1 failed); rerunning the entire suite with two workers passed all 2,084 tests. Impeccable advisory scan returned no findings. No repository hooks or tooling were installed by that scan.

QA browser tab, Vite server and Rails server were stopped; the UI database was dropped. Both `cp_test_filing_record` and `cp_test_filing_record_ui` were dropped after verification; a local catalog query confirmed neither remains. Lifecycle session `manual-20261120-140631-21092-6bb3` reports no active owned resources. Shared Postgres remains available. Branch and checkout remain for Claude and CodeRabbit review; do not merge from this worker.

The unchanged converter environment spec reproduces its failure in isolation: this Mac mini's portable Ruby `rbconfig.rb` (lines 426–432) adds `PKG_CONFIG_PATH` at Ruby startup. The application converter passes the four intended variables with `unsetenv_others: true`; the expected-key assertion then sees Ruby's added variable. No converter code, test or Ruby installation was changed here. A slow-drip response-deadline test also failed under the first full-suite load and passed in the focused rerun.


## Review handoff

PR: https://github.com/Shimizu-Technology/cornerstone-payroll/pull/505. Implementation commit `36a2e75ee818158139ab4b3bab1be6bd5b43f873`; the final follow-up includes the explicit stale-file error wording and this verification record. The PR head is authoritative. Base remains `50e5325b`; #504 had not merged at the final fetch.

The next owner is the lead Claude session. Review the agency identity migration and retained legacy history, integrate/retest with #504, resolve or acknowledge the machine-specific converter test gate, and obtain the planned independent Claude review. CodeRabbit is **rate-limited**, not reviewed, despite its success-labelled check. Do not infer review approval from that label. No merge or production deployment was performed by this worker. Preserve this branch/checkout until the lead completes review and integration.

## Review fix round 1 — Part 1 (2026-11-20)

Worker: Codex Sol on the Mac mini, `/Users/agent/work/cornerstone-payroll-b`, branch `feature/year-end-filing-record`. Started from clean local/origin head `9c55fdad3de5888da6b7593f0654422dc00baa2f`. Scope is Part 1 only; do not merge. Part 2 requires the lead's explicit go-ahead after #504 merges. The independent Claude review accepted the core design; these fixes still need review on the new head.

- **m1:** Rollback counts only split W-2 records and bound/receipt-free events. A migrated 1099 DRT identity can return to the old schema; migration coverage includes both old W-2 and 1099 rows.
- **m2:** Before 2026, the Reports evidence panel keeps the receipt-required path, no agency selector and no final-file selector. W-2 requests normalize to the preserved legacy identity; 1099s retain their single identity. Rejected/needs-correction records can resubmit with receipts without file binding. Prior-year 1099 readiness uses the original payee checks without the new final sign-off. Request and service regressions cover retrieval, receipt enforcement and resubmission.
- **m3:** Filing progress has a separate rescue to an empty array. Its warning contains company ID and tax year only. A regression verifies that a progress exception does not clear the ready stamp or change the preparation payload.
- **m4:** Annual acceptance says “Agency acceptance recorded.” Receipt text and the form header explicitly say optional for 2026+; older and quarterly receipts remain required.
- **m5:** Download JSON includes `current`. A controlled picker selects the newest current file after load/refresh, labels stale files “out of date,” explains how to obtain a missing final e-file, and keeps Refresh outside the label.
- **m6:** Legacy W-2 history appears in the SSA panel only, once across the two agency panels. Older-year history remains the primary editable record.
- **Nits:** Removed the glued stale-readiness suffix; wrong-kind downloads name the expected W-2/1099 e-file. Filing and print deadlines share the weekend rule (2031 tax year is due February 2, 2032); the panel also rolls weekends. The reminder says “need filing attention.” Overview download retrieval uses `DISTINCT ON (company_id, action)` with deterministic newest-first ordering within each group.

Agent-executed QA uses factories/request specs and fictional Chromium transport; no production data or portal calls. The browser suite passes the independent SSA/DRT lifecycle, acceptance without claiming proof, rejection/resubmission, optional receipt controls, stale-file labels and refresh re-selection at 390×1000 and 1440×1000. It checks no horizontal overflow. Request/service specs verify persisted outcomes separately. These screenshots prove the fictional recording interface, not agency delivery or a connected full-app run. Native phone/Safari/WebKit coverage is not run on this host.

Screenshots: `docs/evidence/filing-record/r1-select-390.png`, `r1-select-1440.png`, and refreshed `lifecycle-390.png`, `lifecycle-1440.png`. The Impeccable advisory scan returns `[]`.

Final Part 1 verification:

- `cd api && RAILS_ENV=test TEST_DATABASE_URL=postgres://localhost:5432/cp_test_filing_record_r1 bundle exec rspec` — **7,715 examples: 7,710 passed, 1 failed, 4 pending**, 9m58s. The sole failure is unchanged `spec/services/client_document_converter_process_spec.rb:51`: expected PATH/HOME/TMPDIR/LANG, observed additional `PKG_CONFIG_PATH`. It matches the previously documented portable-Ruby environment failure. The full backend gate therefore remains failed; it is not a clean gate or merge approval.
- Final focused run of `annual_filing_submissions_spec.rb`, `payroll_filing_evidence_recorder_spec.rb`, `year_end/checklist_spec.rb`, `separate_annual_filing_agencies_spec.rb` and the filing-record request spec — **82 examples, 0 failures**. This final run strengthens the prior-year 1099 case: the actual old readiness method runs with a fictional report and raises if it attempts the 2026+ final sign-off.
- `cd api && bundle exec rubocop` — **1,943 files, no offenses**, including final test refinements.
- `cd web && npm run lint && npx tsc --noEmit -p tsconfig.app.json && npx tsc -b` — passed.
- `cd web && npm test -- --maxWorkers=2` — final rerun **2,089 tests, 209 files passed**. Focused panel run: **9 passed**.
- `cd web && E2E_BASE_URL=http://127.0.0.1:4185 npx playwright test e2e/public-filing-evidence.spec.ts --project=public --workers=1` — **2 passed**, including stale selection/refresh at both widths.

Cleanup: both owned Vite server runs were stopped by exact claimed PID; Playwright contexts closed at suite exit. Lifecycle session `manual-20261120-154818-45725-c9aa` reports no active owned resources. The dedicated `cp_test_filing_record_r1` database was verified as local localhost:5432/agent before schema load and dropped after the final run. Borrowed/protected Postgres remains running. No test processes remain from this task. The branch and checkout remain for the lead; there is no runtime-resource handoff.

Next: review this Part 1 push, then wait for the lead's explicit #504-merged go-ahead. Part 2 must reconcile the single 1099 readiness definition, keyed file digests, dynamic step numbering and schema, rebase onto main, rerun all gates and UI acceptance, and push with `--force-with-lease`. Do not merge from this worker. No Part 2 edits or production actions were performed in this round.

## Part 1 CodeRabbit follow-up (2026-11-20)

Starting head: `e7991d731b393bbdd1e5911b7700de6dd23038e2`. Addressed the three lead-approved findings; Part 2 remains on hold.

- `4639130947`: Rollback guidance now requires a release compatible with receipt-free annual history, or disabling annual reads and annual writes until compatibility is restored. Schema preservation remains required.
- `4639130960`: A successful evidence save invalidates pending filing loads. Refresh success, error and completion handlers all ignore invalidated generations; the save clears the pending loading state. The deferred-response regression saves a resubmission first, then resolves an older rejected-state GET and verifies the saved status and history remain visible.
- `4639130964`: W-2 checklist composition renders one panel without an agency prop before 2026 and retains the two separate agency panels from 2026. Parameterized composition tests verify 2025 and 2026. The test supplies the year independently of route normalization, which still clamps earlier route years to 2026; route behavior is unchanged.

Verification on this follow-up: focused `npx vitest run src/components/reports/FilingEvidencePanel.test.tsx src/pages/YearEndChecklist.test.tsx --maxWorkers=2` — **43 passed**. `npm run lint`, `npx tsc --noEmit -p tsconfig.app.json`, and `npx tsc -b` — passed. Full `npm test -- --maxWorkers=2` — **2,092 tests passed across 209 files**. Impeccable advisory scan — `[]`. No browser or backend suite rerun for this focused web/docs follow-up; the prior backend gate limitation remains documented above. No servers, browser tabs or databases were started; lifecycle status reports no active owned resources.
