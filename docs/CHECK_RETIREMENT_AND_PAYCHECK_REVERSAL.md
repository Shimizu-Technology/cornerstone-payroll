# Check retirement and financial reversal (VP-03)

Decision: **Void check retires the payment instrument.** Earned wages remain included in payroll reports, computed/saved YTD, tax payloads, retirement and FICA cap context. The Checks tab says “Check voided — wages still owed, reissue or reverse”. Reissue reserves a new number on the same payroll item; it does not create wages.

`PayrollItem.financially_reportable` and `payroll_included?` exclude an explicit item accounting reversal and a whole-period financial void. They do not inspect check retirement. Existing `.reportable` exclusions, company boundaries and historical cutover rules remain at each reader. `not_voided` describes instrument availability only.

## Explicit reversal

`POST /api/v1/admin/payroll_items/:payroll_item_id/reverse_paycheck` records a written reason, actor and time. It locks the company, period, item and saved YTD records; offsets the item's immutable liability journal, subtracts employee/company YTD, reverses payroll loan payments, excludes the item from financial readers and refreshes taxes with a unique revision key. Repeat reversal is rejected before any effect. Later saved YTD statement snapshots are refreshed without recalculating their earned wages or withholding. A later whole-period void subtracts only the remaining included wages and reverses both original liability postings and item offsets, yielding zero once. Correction-run copies omit individually reversed items.

This narrow operation requires unlinked unpaid payroll and existing YTD ledgers. Exact source accounting corrections, connected reservations, duplicate-linked checks, supplemental corrections, historical dispositions, clearing/issuance, bank confirmation, shared liability payments and filing evidence keep their reviewed correction gates. It never recovers already paid money or automatically releases connected hours.

Instrument retirement preserves the source cancellation capability and exact receipt guards. Prepared/issued connected checks record `payment_cancelled` with retained obligation and immutable frozen hours. Never-prepared stock produces no invented payment receipt. A subsequent whole-period financial void records the distinct source `payment_voided` once, including a check already retired earlier. Manual allocations receive a fresh sync after whole-period reversal; direct lines and financial links deduplicate their financial-void receipts.

## Reader inventory

Baseline is staging-v2 `5e5e7253`. Every baseline `not_voided` occurrence is accounted for below; line numbers identify the original readers. Financial inclusion means retained-check wages remain included and explicitly reversed payroll is excluded.

| Reader | Baseline lines | New semantics |
|---|---|---|
| `api/app/controllers/api/v1/admin/checks_controller.rb` | 57, 112 | Earnings statements use payroll inclusion (57); check rehearsal selection remains instrument-only (112). |
| `api/app/controllers/api/v1/admin/pay_periods_controller.rb` | 979, 1051, 1194, 1908, 1918 | Financial inclusion; existing reportability, company, date and historical restrictions retained. The completed whole-period void audit deliberately retains the reversed period totals, excluding earlier individual reversals. |
| `api/app/controllers/api/v1/admin/pay_stubs_controller.rb` | 90, 194, 240 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/controllers/api/v1/admin/payroll_intake_imports_controller.rb` | 280, 281 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/controllers/api/v1/admin/payroll_items_controller.rb` | 15 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/controllers/api/v1/admin/reports_controller.rb` | 882, 1035, 1300, 1424, 1856, 1857, 1858, 1884, 1892, 2494, 2645, 2657 | Financial reports and taxes use payroll inclusion. Active check references (884, 1035, 1300) retain instrument filtering. |
| `api/app/controllers/api/v1/client/reports_controller.rb` | 43, 44, 45 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/models/employee.rb` | 455, 479, 721 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/models/employee_ytd_total.rb` | 83 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/models/payroll_item.rb` | 111, 112 | Instrument scopes retained; new financially_reportable/payroll_included? are independent of instrument availability. |
| `api/app/services/annual_payroll_summary.rb` | 94, 211 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/check_generator.rb` | 536 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/check_number_batch_correction_service.rb` | 208 | Active instrument number range only; unchanged. |
| `api/app/services/check_number_correction_service.rb` | 132 | Active instrument number range only; unchanged. |
| `api/app/services/check_signoff_pdf_generator.rb` | 135 | Checks available for signoff only; unchanged. |
| `api/app/services/check_signoff_sheet_generator.rb` | 111 | Checks available for signoff only; unchanged. |
| `api/app/services/employee_document_readiness.rb` | 34, 35 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/form500_generator.rb` | 123 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/form_1099_nec_aggregator.rb` | 79 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/form_941_gu_aggregator.rb` | 260, 481, 495 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/issue_corrective_paycheck_service.rb` | 437, 682, 698, 916 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/migration_promotion/apply.rb` | 153, 215, 218 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/migration_promotion/prepare_payment_issuance.rb` | 98 | Issuable instruments only; unchanged. |
| `api/app/services/migration_promotion/preview.rb` | 119, 120, 121 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/pay_period_comparison_builder.rb` | 144 | Financial comparison includes retired checks; the explicit whole-period-void source audit exception still includes original amounts. |
| `api/app/services/pay_period_lifecycle_service.rb` | 121, 129, 162 | Finalization participation/source/pay-basis checks and FIT obligation totals use payroll inclusion; instrument checks remain separate. |
| `api/app/services/pay_stub_generator.rb` | 520 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/payroll_earnings_ytd_breakdown.rb` | 78 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/payroll_final_record_service.rb` | 45, 196 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/payroll_parallel_run_review_service.rb` | 88 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/payroll_retirement_calculation.rb` | 543, 560 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/payroll_statement_ytd_breakdown.rb` | 363 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/payroll_tax_sync_payload_builder.rb` | 27 | Active snapshot includes earned payroll; whole-period void carries remaining original rows with positive amounts and explicit void status. Individual reversals are listed separately, allowing zero remaining balance. |
| `api/app/services/quarterly_compliance_packet_builder.rb` | 86, 97, 628 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/quickbooks_payroll_report_data.rb` | 37 | Default financial report includes retired instruments. Explicit include_voided keeps the historical/audit option for financially reversed rows. |
| `api/app/services/replace_check_service.rb` | 378, 396 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/test_workspace/cloner.rb` | 75, 156 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/test_workspace/preview.rb` | 148 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/time_tracking/exact_line_correction_service.rb` | 187 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/time_tracking/financial_correction_service.rb` | 90, 155 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/training_replay/benchmark_snapshot.rb` | 15 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/training_replay/cloner.rb` | 102, 117, 205, 206 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/training_replay/preview.rb` | 106 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/transmittal_log_pdf_generator.rb` | 22, 109, 218 | Financial wage/tax totals use payroll inclusion (22, 218); active check numbers retain instrument filtering (109). |
| `api/app/services/unified_transmittal_bootstrap_service.rb` | 73 | Obligations use included payroll; payment specs additionally reject retired instruments. |
| `api/app/services/w2_filing_inputs_fingerprint.rb` | 46 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/w2_gu_aggregator.rb` | 103 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |
| `api/app/services/w2_gu_preflight_validator.rb` | 99 | Financial inclusion; existing reportability, company, date and historical restrictions retained. |

Direct financial filters were also updated in `PayrollHistoryQuery` (SQL join), `PayPeriodCorrectionEvent` (remaining financial snapshot), `PayPeriodCorrectionService` (YTD reversal and correction copying), `PayrollLiabilityPostingService` (restatement capture), `PayrollLiabilityReconciliationService` (remaining unclassified obligations), `PayrollFinalRecordService` (retired instruments remain outstanding), `EarningsStatementEligibility`, current-item YTD components in `PayStubGenerator`/`PayrollEarningsYtdBreakdown`/`PayrollStatementYtdBreakdown`, pay-date correction snapshots, client period/report controllers, go-live totals, loaded period aggregates, FIT generation, `PayPeriodDetail` summaries and `PayRunWorkspace` overview/statement counts. Check printing, check-number assignment, delivery, bank proof and check replacement continue to inspect instrument status.

`TimeTracking::ManualAllocationService` only releases a committed source allocation after financial payroll reversal; instrument retirement and repeated cancellation sync keep its reserved hours. Historical reconciliation uses the public cancellation predicate and requires the original exact receipt before replay.

## Existing data and release

The migration adds nullable reversal fields and an actor foreign key. It does not rewrite existing voids. Deploy the migration with the API/web change.

**Required release step:** an authorized operator runs `bin/rails payroll:legacy_check_voids` read-only in production and gives the CSV to an accountant for review. The task sets its transaction READ ONLY and lists committed, financially included items with an old instrument void event lacking retained-obligation evidence and no matching item reversal. IDs, check reference, amounts and reason are retained for review. No production run or data repair was performed by this task.

Review the candidates against saved YTD, liability and source/payment evidence before any accounting or filing repair. New explicit retirements carry retained-obligation audit metadata and are omitted from the legacy list; whole-period and item financial reversals are also omitted.

CST payloads now identify explicitly reversed items and permit a zero remaining balance. Producer behavior is verified with a mocked receiver; no live CST/provider call was made. Combined deployment/receiver verification remains with integration.

## Validation evidence

The task evidence, exact gate counts and viewport scenario results are recorded in `output/payroll-aire-review-2026-10-24/impl/payroll-void/RESULT.md` outside this repository. Required viewports are 1280×800 and 390×844. The original $900 failure is retained in `regression-before.log`; the UI regression failure is retained in `ui-before-node24.log`.

Shared-file touches: inclusion scopes only in `issue_corrective_paycheck_service.rb` (four readers); source/participation validation scopes and FIT inclusion in `pay_period_lifecycle_service.rb`. No annual FICA calculation logic or `payroll_review/calculation_snapshot.rb` edits.

Single-paycheck reversal scopes employee payment evidence to the selected item. Other employees' delivered, cleared or direct-deposit payments do not block it; shared filing/liability payment guards remain period-wide. Its own issued/cleared or positive direct-deposit payment remains blocked.

Reversal liability entries net all prior postings by `component_key`, omit zero balances, and record the complete input-entry audit in `metadata.reverses_entry_ids`. Whole-posting reversal retains its existing immediate-parent `reverses_entry_id`; no existing reader interprets the former single-item singular key. The database requires the reversal timestamp, actor and reason to be either all NULL or all populated.

Rollout: run `payroll:legacy_check_voids` read-only in production. The accountant classifies each legacy void as instrument retirement or financial reversal. Apply `ReversePaycheckService` for financial reversals before the first tax sync or filing export after deploy. A guarded reversal must be resolved through its reviewed correction path before exports resume; do not bypass payment/source/filing guards.

Correction preview and issuance both reject financially excluded originals, including checkless zero-net payroll. Issuance rechecks the inclusion guard after refreshing the original under its lock. Whole-period source release uses the actual financial reversal audit plus exact linked-line ownership and receipt deduplication; legacy retired checks do not require newer retained-obligation event metadata.
