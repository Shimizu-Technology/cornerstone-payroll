# PR #501 round 4 — 2026-11-20

Started from clean `a470230ffae6f050b85cead78450ddc3f2c91a95`, equal to `origin/feature/efw2-w3ss`, on the named branch in `/Users/agent/work/cornerstone-payroll-b`. Base remains `a3aab687`. Production and the other checkout were not accessed.

Cornerstone staff use the Year-End clients list to prioritize client filing work; the submitter profile belongs to the organization and editing requires organization administration. W-3SS is a records PDF, while the W-2 e-file is the upload artifact. Source: the task, FilingSubmittersController, StaffRolePolicy, YearEnd::Checklist, and the round-3 validation record.

## Diagnosis

The red message in the round-3 image means the profile GET rejected. It is not evidence of an absent database record: `show` already used `find_or_initialize_by`, returning 200 without creating a record. Nor is GET admin-only: the inherited staff gate permits accountants, and only PATCH checks `manage_organization`. Request specs on this checkout confirm both behaviors. No route/serializer regression was reproduced.

The earlier screenshots were made with a temporary React mount harness and intercepted API responses, without application authentication (documented in round3-validation.md). The profile request was not successfully supplied in that run. The most likely cause is an unhandled/unavailable profile request in that synthetic harness, rather than a production permission bug. The exact old request status and deleted harness could not be recovered; this historical detail remains an inference, not a verified HTTP trace. The new browser harness explicitly handles every requested API route and rejects unexpected routes.

The real UI gaps were that all GET rejections became the same red error, missing profiles had no setup summary, and genuine failures had no retry. The API now returns `exists`; the card distinguishes setup, completeness, read-only staff, expected denied access, and retryable load failure. Existing staff-read/admin-write authorization remains covered. Only real load failures show the red load error and Try again.

The W-3SS checkbox came from `wage_filing_documents` assigning the same confirmation to both records. Confirmation now lives on the W-2 e-file descriptor alone. PrintAndFileStep already opts in via each document's `draft_confirmation`; regression tests cover W-3SS and an additional future 1099-style draft without opt-in. W-3SS remains a draft PDF before readiness.

## Agent-executed affected-flow QA

Local Playwright Chromium, 1440×1100 and 390×1100, real YearEnd page/styles and PrintAndFileStep, synthetic intercepted profile/overview responses and synthetic download bytes. Overview data came from the previous factory-generated overview; checklist data was regenerated from the current service in a rolled-back transaction. No real authentication, agency upload, or production data was used. API specs separately verify authorization, profile persistence, checklist fields, and actual file endpoints.

Five scenarios passed at both widths (10 viewport executions): admin can open editable profile; staff sees completeness and disabled inputs without a save control; missing profile shows setup instead of error; HTTP 500 shows an error and Try again then recovers; W-3SS has no checkbox and downloads in draft mode while W-2 requires confirmation. No horizontal overflow. This is affected-flow coverage, not a full application audit. Native mobile/Safari was not run on this headless Mac mini.

Screenshots in this directory:
- `r4-clients-admin-{1440,390}.png`
- `r4-clients-staff-{1440,390}.png`
- `r4-clients-missing-{1440,390}.png`
- `r4-clients-failure-before-retry-{1440,390}.png`
- `r4-clients-failure-{1440,390}.png` (recovered)
- `r4-print-draft-{1440,390}.png`

## Validation

`agent-postgres start` confirmed the shared local test service. Before schema loading, SQL confirmed `cp_test_efw2_r4`, user `agent`, loopback `::1`, port 5432. All Rails runs used `RAILS_ENV=test TEST_DATABASE_URL=postgres://localhost:5432/cp_test_efw2_r4`.

- `bundle exec rspec spec/requests/api/v1/admin/filing_submitters_spec.rb spec/requests/api/v1/admin/wage_filing_files_spec.rb spec/requests/api/v1/admin/year_end_spec.rb spec/services/year_end/checklist_spec.rb spec/models/filing_submitter_spec.rb`: 81 examples, 0 failures. Full RSpec was not run for these bounded changes.
- `bundle exec rubocop`: 1,930 files, no offenses.
- `npx vitest run src/components/year-end/PrintAndFileStep.test.tsx src/components/year-end/FilingSaveState.test.tsx`: 20 tests, 2 files passed.
- `npm run lint`, `npx tsc --noEmit -p tsconfig.app.json`, CI's `npx tsc -b`: passed.
- `npm test`: 208 files / 2,079 tests passed.
- Impeccable 4.6.0 on FilingSubmitterCard: empty findings array.

No new migration or infrastructure. Production frontend build expected when the lead merges because this changes frontend source. PR remains held for lead review; no merge or release was attempted.

`git diff --check` passed. All task-created Chromium instances closed in finally blocks; the preview tab was closed. Lifecycle session `manual-20261120-104816-85727-79f6` reports no active owned resources. Both owned Vite processes were stopped; temporary harness/cache files were removed and `cp_test_efw2_r4` dropped. The shared PostgreSQL service was left available. The named worktree/branch is retained for the lead.
