# Pub 1220 review round 2

## Scope and decisions

Implementation worker on the Mac mini; `/Users/agent/work/cornerstone-payroll-b`, `feature/1099-pub1220`, starting at verified clean local/origin `4c4220f7271186919655552b986edc7f4c8eadba`. PR #503 targets `main` and stays open for the MacBook lead; no merge or deployment is authorized for this round. The existing [implementation brief](../PUB1220_1099_E2_HANDOFF.md) establishes the staff workflow, filing population and E1 boundary. This ledger supersedes round-1 verification for these changes.

- The client list sums gross and `COALESCE(withholding_tax, 0)` by employee in one batched query, with the aggregator's committed/reportable scope. Nonzero withholding makes a below-threshold contractor reportable. Request coverage checks a $500 contractor with $50 withheld and no TIN, then restores a TIN and verifies Ready.
- Individual name controls retain leading `de la`, `de las`, `de los`, `del`, `de`, `san`, `santa`, and `st` plus the following word. All requested surname examples and the additional particle variants are parameterized.
- First payee name lines end at the last space through position 40. Continuation starts without a space. Only a single word longer than 40 is hard-cut. Both word-boundary and long-word cases verify the exact two output fields.
- When threshold and withholding both apply, the threshold reason wins. Existing UI and PDF consumers both use their ordinary Reportable display; below-threshold withholding retains its explicit explanation.
- Payer/transmitter names without any usable letter or number fail with a named problem before records are written.
- XLSX retains BigDecimal values in the shared exporter. 1099 compensation/withholding detail and monetary totals receive money styles. XML tests verify numeric values and styles, alongside formula-injection coverage.

## Acceptance and limitations

Agent-executed affected-flow coverage uses factory-backed service and request tests: list/checklist parity and recovery, complete B-record names/name controls, refusal before output, filing reason, and generated XLSX numeric/money cells. No frontend source changed, so prior component journeys were not rerun. Browser/device journeys, authenticated Clerk integration, E1 integration, external GuamTax upload and DRT acceptance were not run in this round. No production records were accessed.

Shared-guidance freshness validation still fails because this host lacks `~/.config/shimizu-technology/agent-context.json`; applicable synced skills were read directly. The host setup was left unchanged.

## Verification

Final focused run: 288 examples, 0 failures:

`cd api && bundle exec rspec spec/services/form1099_pub1220_generator_spec.rb spec/services/form_1099_nec_aggregator_spec.rb spec/services/spreadsheet_report_exporter_spec.rb spec/requests/api/v1/admin/year_end_spec.rb spec/requests/api/v1/admin/form1099_filing_files_spec.rb spec/requests/api/v1/admin/reports_spec.rb`

All Rails commands used `RAILS_ENV=test TEST_DATABASE_URL=postgres://localhost:5432/cp_test_pub1220_r2`. Database identity was checked with SQL before loading the schema: `cp_test_pub1220_r2`, role `agent`, loopback `::1`, port `5432`.

- `cd api && bundle exec rubocop`: 1,937 files inspected, no offenses.
- `cd web && npm run lint`: passed.
- `cd web && npx tsc --noEmit -p tsconfig.app.json`: passed.
- `cd web && npx tsc -b`: passed.
- `cd web && npm test`: 209 files, 2,083 tests passed.

Logs: `/tmp/r2-focused-final.log`, `/tmp/r2-rubocop.log`, `/tmp/r2-lint.log`, `/tmp/r2-tsc-app.log`, `/tmp/r2-tsc-build.log`, `/tmp/r2-web.log`, `/tmp/r2-rspec-full.log`.

`cd api && bundle exec rspec`: **7,689 examples, 1 failure, 4 pending**, 15m07s. The sole failure is the known host RubyGems environment issue in `client_document_converter_process_spec.rb:51` (assertion at line 58): child environment includes extra `PKG_CONFIG_PATH`. The converter and its isolation assertions were not changed. The four pending transaction-pooler cases require external pooler URLs. The full Rails gate is **not clean**; no additional failures appeared.

## Cleanup and lead return

Lifecycle session `manual-20261120-131057-7074-bb56`: all owned test processes exited; cleanup/status reports no active owned resources. No app server or browser was started. The task database `cp_test_pub1220_r2` was dropped after tests; a `pg_database` query returned zero matching databases. The pre-existing protected PostgreSQL service remains running. Branch and checkout stay available for the MacBook lead, with no runtime handoff.

Next action: independent lead review of round 2, E1 integration and combined-flow verification. PR remains on hold; no merge or production deployment was performed. CodeRabbit's prior status does not establish review of these new changes.
