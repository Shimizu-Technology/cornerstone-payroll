# EFW2 / W-3SS acceptance and review handoff

November 20, 2026. Dedicated clone: `/Users/agent/work/cornerstone-payroll-b`, branch `feature/efw2-w3ss`, base `e882bf15` (`origin/main`). Scope comes from the milestone 1 part D brief and the repository's November 17 year-end research. Cornerstone's Dafne, Mark and Benjo prepare client year-end filings; the app already aggregates wages, records filing responsibility and binds “ready” to a fingerprint. This change adds file generation and the identities/settings needed by that workflow. It does not upload returns.

Acceptance owner: implementation agent. Fixtures: factory-generated Example Guam client/employee and practice profile in task-specific local PostgreSQL databases. No production data or systems were used. Browsers: local Playwright Chromium, 1280×900 and 390×844 CSS viewports. Phone resizing does not establish physical iPhone/Safari behavior; WebKit was not run on this headless Mac mini.

| Required scenario | Result | Evidence |
|---|---|---|
| Year-End shows incomplete practice profile; admin saves it; reload retains it | Passed at desktop and phone widths | `evidence/efw2-w3ss/submitter-desktop.png`, `submitter-phone.png` |
| Employer defaults remain N/R; Change saves establishment A001; saved value reaches the file | Passed; final file RE 26–30 is `0A001` | Endpoint persistence spec and positional parser; actual downloaded bytes inspected |
| Draft requires confirmation and downloads with DRAFT filename | Passed on phone; desktop controls inspected; 7×512-byte ASCII records with CR/LF | Actual local download and component tests |
| Mark synthetic client ready, download final EFW2 and W-3SS | Passed; final filenames, file contents, PDF and audit contract checked | `final-phone.png`, `final-desktop.png`; request specs |
| Employee suffix saves and survives reload; changing identity expires readiness | Passed; JR persisted and UI returned to draft; final file RW 62–65 is `JR  ` after renewed sign-off | `suffix-phone.png`; fingerprint and request specs |
| W-3SS totals and alignment | Passed for 2026 Copy 1 records overlay; mixed D+AA test verifies Box 12a | `w3ss-alignment.png`; PDF text extraction test |
| Invalid identities/addresses, negative/overflow amounts, wage base, SS tax maximum, total discrepancies | Passed automated failure cases; no partial file returned | Generator specs |
| Auth, filing-responsibility draft/final capability, no-store and download auditing | Passed automated | Request specs |
| SSA AccuWage / GuamTax upload acceptance | Not run: operator accounts and 2026 upload windows required | Required before live filing; no upload attempted |

The saved-outcome check caught the employer fields missing from strong parameters; that was fixed and retested through the UI, database readback, endpoint specs and downloaded byte positions. Early suffix QA exposed incomplete synthetic fixture setup (a department in another company and no W-4 effective date); the local fixture was corrected before the save/reload acceptance run. No unrelated employee-form behavior was changed.

Automated verification:

- Final combined generator/model/migration/settings/download/company/year-end specs: 95 examples, zero failures.
- Migration round-trip on populated tables: 1 example, zero failures.
- Frontend: lint and `tsc --noEmit` pass; Vitest 205 files / 2,047 tests pass.
- RuboCop: 1,921 files, no offenses at the recorded pass.
- Impeccable 4.6.0, telemetry disabled, all changed UI paths: `[]` findings.
- Full backend suite: final result is recorded in the PR and final task report.

Deployment requires one additive migration, the API and website. There is no data backfill; existing employers get N/R defaults. Add employer filing contacts and the practice submitter profile before export. Existing readiness fingerprints change because filing identity/settings now participate. The checked-in 2026 IRS PDF is the only spec/form PDF added; SSA PDFs remain outside Git.

The self-contained filing row is immediately after Mark W-2s ready. As of the last fetch, the other worker's Print and file step was absent from `origin/main`; the lead can place this row there during integration. The field inventory and source decisions are in `EFW2_W3SS_IMPLEMENTATION.md`.

The lead's independent Claude review and CodeRabbit review remain separate from implementation QA. Do not merge this PR under this task's explicit hold instruction. AccuWage/GuamTax acceptance remains the operator's next release check.
