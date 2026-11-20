# PR 503 review fixes, 2026-11-20

Worktree: `/Users/agent/work/cornerstone-payroll-b`, branch `feature/1099-pub1220`, initial head `e14ada4f`. HEAD matched origin and the tree was clean after fetch. The other Cornerstone checkout and production were not accessed. Fixtures are synthetic factories.

Cornerstone staff use this flow to prepare annual contractor returns and download a validated GuamTax file and matching records-only totals. Acceptance for this round: named identity/width errors before output; withholding makes a payee reportable below the threshold; exact Box 4 totals; correct name lines/control and stable account IDs; explicit draft/TCC instructions; access restrictions retained. Sources: worker brief, existing `PUB1220_1099_E2_HANDOFF.md`, generator/aggregator/checklist/request code at the initial head, and the locally retained IRS Pub 1220 tables and Exhibit 1 (`/tmp/cp-p1220.txt`).

## Record and report rules

SSN payees use the individual's name on B 288–327 and the business name on 328–367. EIN payees use the business name first. An otherwise unused second line carries a primary name exceeding 40 characters, up to the combined 80-character capacity. Names beyond the available lines fail with a named problem. Combined street lines must fit 40 characters; no address truncation occurs.

Surname controls use the first hyphenated/double surname per the lead's decisions, retaining `De La` as part of the surname. Regression examples: Li-Smith → `LI  `, Garza Morales → `GARZ`, Ko Tenorio → `KO  `, De La Cruz → `DELA`. Business controls remain blank where indeterminate.

B 21–40 carries the stable employee database ID with a `C` prefix and at least six digits (`123` → `C000123`). This is stable across repeated exports and corrections; it contains no TIN. Unidentified one-off checks remain blocked before B records are written. E1's future one-off identity resolver must preserve a stable payee account key when it begins producing exportable rows.

Nonzero withholding makes a contractor reportable regardless of compensation. The row includes `requires_filing: true` and `filing_reason: "tax withheld"`. Counts, reportable compensation, Box 4, and B/C/F records use that same population. A $1,500 payee with no withholding remains excluded. Withholding rows/totals remain BigDecimal; Rails JSON encodes them as decimal strings. The report formatter already accepts number/string values; its types now reflect this. Existing compensation serialization remains unchanged to keep E1's rebase small. UI and preparation-PDF threshold labels include withholding, and each withheld row shows its reason. The 1096 formatter uses integer cents/divmod and thousands separators.

## QA execution

Agent-executed affected-flow checks used actual React components in a temporary synthetic API harness in the shared Chromium preview at 390×844 and 1440×1000. This establishes component behavior, not an authenticated Clerk-to-API journey. Request specs exercise backend generation with the real aggregator, including EIN/business fields, a below-threshold withheld payee, and blocking an unresolved one-off check; duplicate-check reconciliation removes that check from the filing population.

Passed: whitespace TCC prompt, edit/save confirmation and prompt removal, non-editor TCC as plain text ending in a period, draft confirmation enabling the e-file button, named simulated download error, disabled practice-copy rows, and no horizontal overflow at either width. Screenshots refreshed under `docs/evidence/pub1220/`: `draft-390.png`, `error-390.png`, `submitter-1440.png`, `submitter-saved-390.png`, `readonly-practice-390.png`, `readonly-practice-1440.png`.

Not run: native phone keyboard/Safari/WebKit (unsupported here), external GuamTax upload, DRT validation. E1's final-readiness integration remains a separate dependency. No claim of external filing acceptance.

## Review and remaining questions

Controller service extraction is deferred by the lead to a follow-up refactoring all four filing downloads together, preserving the EFW2/W-2GU conventions shipped in #501/#502.

Open operator questions remain: which Pub 1220 edition DRT validates for 2026; DRT-issued TCC instructions; whether off-island payees must be included; whether Cornerstone should record a sole proprietor using an EIN as an individual or business. Final downloads require a TCC in the current implementation. GuamTax's treatment of the test indicator is unconfirmed; drafts still carry T position 28 = T and warn not to upload as a filing.

The shared-guidance check failed because this host has no `~/.config/shimizu-technology/agent-context.json`; relevant installed guidance was read directly. This host setup issue was not changed.

## Final automated gate and cleanup

- Focused final Rails run: **78 examples, 0 failures** (`form1099_pub1220_generator`, `form_1099_nec_aggregator`, `form1099_filing_files`, `filing_submitter`, `year_end/checklist`).
- `cd api && bundle exec rspec`: **7,667 examples, 1 failure, 4 pending** (10m18s). The only failure is the pre-existing host RubyGems environment issue in `client_document_converter_process_spec.rb:51`: RubyGems adds `PKG_CONFIG_PATH` even under `env -i`. Reproduced outside Rails; no converter isolation checks were weakened. Four pooler tests require external pooler URLs. The full gate is therefore **not clean** on this host.
- `cd api && bundle exec rubocop`: **1,937 files inspected, no offenses**.
- `cd web && npm run lint && npx tsc --noEmit -p tsconfig.app.json && npx tsc -b && npm test`: **passed; 209 files, 2,083 tests**.

Logs: `/tmp/r1-focused-final.log`, `/tmp/r1-rspec-final.log`, `/tmp/r1-rubocop.log`, `/tmp/r1-lint.log`, `/tmp/r1-tsc.log`, `/tmp/r1-web-full.log`. All final code changes preceded the full run. No merge or deployment was performed.

Lifecycle session `manual-20261120-124345-950-bb8e`: Vite PID 1487 stopped; preview tab `tab_4m_89c280d8-30cd-43c8-87b2-8d384475a23b` closed/released; full RSpec PID 3052 exited. Status: no active owned resources. `cp_test_pub1220_r1` was dropped and its absence verified in `pg_database`. Shared PostgreSQL remains borrowed/running. The branch and worktree remain for the lead.
