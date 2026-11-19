# EFW2 / W-3SS fix round 1

November 20, 2026. PR #501, `feature/efw2-w3ss`, isolated checkout `/Users/agent/work/cornerstone-payroll-b`. Starting head `2f0e683bb8259674cc3adca528ae8531ced45dd0` matched origin and was clean. This report covers that source plus the fix-round changes committed with it. Target branch: `main`. Hold for the lead's review; do not merge.

Cornerstone staff prepare each client's 2026 W-2GUs for SSA and Guam DRT. Acceptance for this round: the list and checklist agree on new filing problems; draft and final files require Cornerstone responsibility; format problems appear before sign-off; full-SSN files require delegated client management; the phone and desktop flows remain usable. Source: the lead's review brief, current controllers/services/policies, and SSA Pub 42-007 tax year 2026 v4 (local PDF read only, not committed).

## Review fixes

| Item | Change | Source |
|---|---|---|
| M1 | Count missing employer filing contact and shared format issues on both list and checklist; NULL-contact parity spec covers count and status. | `api/app/services/year_end/clients_overview.rb`, `api/spec/services/year_end/checklist_spec.rb` |
| M2 | Both modes require a recorded Cornerstone W-2 decision and no responsibility blockers. Draft skips only current readiness. | `api/app/controllers/api/v1/admin/reports_controller.rb` |
| M3 | Public non-raising `problems` powers employer/people issues and mark-ready blockers; submitter missing/invalid details appear on the year-end card. Final generation still validates submitter details. | `api/app/services/efw2_w2_gu_generator.rb`, `api/app/services/year_end/checklist.rb`, `web/src/components/year-end/FilingSubmitterCard.tsx` |
| 1 | Employee messages use names; negative/overflow checks identify each box, including Box 12. | `api/app/services/efw2_w2_gu_generator.rb` |
| 2 | Normalize ’, ‘ and ʼ before transliteration; preserve field-specific employee name restrictions. | `api/app/services/efw2_formatting.rb` |
| 3 | Only R, F, A and M are accepted by the model, generator and editor. | `api/app/models/company.rb`, `web/src/components/year-end/EmployerFilingSettings.tsx` |
| 4 | All three SSA relational edits: Medicare wages cover SS wages plus tips; SS tax requires SS wages/tips; Medicare tax requires Medicare wages. | `api/app/services/efw2_w2_gu_generator.rb` |
| 5 | Write occupation codes only for positive TP. | `api/app/services/efw2_w2_gu_generator.rb` |
| 6 | Shared SSA save-time checks; first-save race handling; repeat saves update the existing profile; workspace update blocked. | `api/app/models/filing_submitter.rb`, `api/app/controllers/api/v1/admin/filing_submitters_controller.rb`, `api/app/policies/test_workspace_safety_policy.rb` |
| 7 | Seven literal 512-character golden records transcribed independently from spec positions, with full-record equality. | `api/spec/fixtures/efw2_2026_golden.txt`, `api/spec/services/efw2_w2_gu_generator_spec.rb` |
| 8 | One contact editor; visible missing/invalid issues; loading state; field helper lines; hide W-2 settings for 1099-only clients. | `web/src/components/year-end/EmployerStep.tsx`, `EmployerFilingSettings.tsx`, `FilingSubmitterCard.tsx` |
| 9 | Requested e-file/W-3SS/submitter wording and draft confirmation. | `web/src/components/year-end/W2FilingFileRow.tsx`, `FilingSubmitterCard.tsx` |
| 10 | Correct employer-contact comment. | `api/app/services/efw2_w2_gu_generator.rb` |
| Added access finding | EFW2 requires per-client `manage_client_administration`; delegated accountant/admin allowed, plain accountant denied. W-3SS retains report authorization. Profile edits use `manage_organization` because the details affect every client. | `api/app/policies/staff_role_policy.rb`, `api/app/controllers/api/v1/admin/filing_submitters_controller.rb`, `web/src/pages/YearEndChecklist.tsx` |

The clients list now performs the same report-based format preflight for every W-2 client. This deliberately adds per-client report reads instead of silently undercounting People issues. The query regression spec bounds that work to 18 additional queries per extra client in its native/import-capable fixture. Other grouped list lookups and stale-readiness behavior remain. A future batch preflight could reduce this cost without changing validation.

## Agent-executed browser acceptance

Factory-only data in `cp_test_efw2_r1_ui` on localhost. Shared preview Chromium/Playwright browser, 1280×900 and 390×844 CSS viewports. No production access. Phone resizing does not establish physical iPhone/Safari behavior; WebKit cannot start on this Mac mini.

| Scenario | Result and saved outcome | Evidence |
|---|---|---|
| Missing submitter detail and save/reload | Passed: missing BSO User ID shown; save persists `ABCDEFGH`; success message and database readback confirmed. | `evidence/efw2-w3ss/submitter-desktop.png`, `submitter-phone.png` |
| Employer settings and single contact editor | Passed: helper lines visible; one contact input; establishment A001 saved and verified in database and final RE 26–30 (`0A001`). Missing contact displays its fix and can be repaired here. | `employer-desktop.png`, `employer-phone.png` |
| Draft confirmation and download | Passed: initially disabled; confirmation enables download; actual DRAFT file downloaded. Missing submitter refuses download with a field-specific error. | `draft-desktop.png`, `draft-phone.png`; downloaded 3,598-byte file |
| Ready and final downloads | Passed: reviewed the synthetic tax-liability warning in UI, marked ready, persisted sign-off, downloaded FINAL EFW2 and records PDF. File has 7×512-byte ASCII records plus CRLF. | `final-desktop.png`, `final-phone.png`; request specs and downloaded bytes |
| Accountant without client management | Passed: EFW2 disabled with the exact requested reason; records PDF remains enabled. | `access-desktop.png`, `access-phone.png`; denied/delegated/admin request specs |
| 1099-only client | Passed: changing the synthetic decisions hides the e-file card and W-2-only settings; checked at 390px with no horizontal overflow. | Browser DOM checks |

All required affected browser scenarios passed. Retained suffix/PDF-alignment images are prior-round evidence, not new claims. No AccuWage, BSO or GuamTax submission attempted; operator acceptance remains necessary before actual filing.

## Automated checks

- Focused backend and final recheck: **78 examples, 0 failures** (`/tmp/efw2-recheck.log`).
- Full `bundle exec rspec`: **7,551 examples, 1 failure, 4 pending**, 11m20s (`/tmp/efw2-full-rspec.log`). The only failure is the known mini-only converter environment-isolation spec: the child Ruby adds `PKG_CONFIG_PATH`. Left unchanged as instructed; GitHub CI is the authority. The four pending cases require an external transaction pooler.
- `bundle exec rubocop`: **1,922 files, no offenses** (`/tmp/efw2-rubocop.log`).
- `npm run lint` and `npx tsc --noEmit`: pass.
- `npm test`: **206 files, 2,049 tests pass** (`/tmp/efw2-web-test.log`).
- `IMPECCABLE_NO_TELEMETRY=1 npx impeccable@4.6.0 detect --json` on all changed UI paths: **[] findings** (`/tmp/efw2-impeccable.json`).

The focused command is `bundle exec rspec spec/requests/api/v1/admin/wage_filing_files_spec.rb spec/models/filing_submitter_spec.rb spec/requests/api/v1/admin/filing_submitters_spec.rb spec/services/efw2_w2_gu_generator_spec.rb spec/services/year_end/checklist_spec.rb spec/requests/api/v1/admin/year_end_spec.rb`.

Both local database identities were checked with `current_database()`, `inet_server_addr()` and `inet_server_port()` before schema loading. RSpec uses `RAILS_ENV=test TEST_DATABASE_URL=postgres://localhost/<task-db>`. Deterministic factory phone/email/SSN values prevent random invalid e-file fixtures from masking validation results.

## Deploy notes and disposition

After deployment, W-2 clients need an employer filing contact name. Existing W-2 readiness becomes stale because the fingerprint shape changed; staff must resolve the checklist and mark ready again. Cornerstone's e-file details must be completed before downloading, but submitter details are intentionally outside the client fingerprint. Production frontend build is expected when merged because UI source changed; nothing was deployed or merged by this worker.

Both task databases (`cp_test_efw2_r1`, `cp_test_efw2_r1_ui`) were dropped. Owned Rails/Vite processes and the preview tab were closed; lifecycle session `manual-20261120-085348-60758-d117` reports no active owned resources. No runtime handoff. The named branch and checkout remain for the lead. Shared PostgreSQL, Immich, Hermes, Syncthing, Tailscale, Jerry/OpenClaw and LM Studio were left available.

Shared-guidance freshness check could not run: this host lacks `~/.config/shimizu-technology/agent-context.json`. Applicable installed/synced guidance was read directly. No host configuration, shared service or other worker's checkout was changed. No further delegation was used. Final independent review belongs to the lead; no new review is claimed clean here.
