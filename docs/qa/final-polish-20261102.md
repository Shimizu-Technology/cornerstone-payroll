# Final payroll polish — November 2, 2026

Base: `origin/staging-v2` at `a663d7a5` (includes #417 and docs-only #418). PR held for review; no merge or deployment authorized. Local fixtures only.

Cornerstone Payroll supports Dafne (admin), Chels, and accountants Mark and Benjo. They enter hours, calculate and review client payroll, and use statements/registers to reconcile saved pay. Preserve payroll calculations, deletion rules (#417), distinct field identities, and screen positions.

Sources: final staging retest ledger, section “Retest 2026-11-02 (08f1041d / AIRE 4698a7dc)” and its `downloads/retest-08f1041d/` PDFs; Brain-Dump `work/shimizu-tech/Cornerstone/payroll-priorities-and-aire-reconciliation-2026-09-19.md` (distinct payroll components and reconciliation requirements); current code in PayPeriods, PayStubGenerator, ReportsController and PayrollRegisterPdfGenerator. Historical notes are requirements, not release certification.

## Required acceptance (agent executes, local only)

- D1: at 1440 and 390 CSS pixels, open Delete for a calculated local run. Dialog names client, dates, pay date, status, employees and gross; explains permanent loss of run/hours; checkbox gates deletion for 10+ employees or any entered hours. Cancel preserves the run, success removes it and names it in a toast, refusal preserves it and reports the server error. Check acknowledgement reset, keyboard access and no overflow. Unit coverage includes small zero-hour runs and failed detail loading.
- P1: render before/after earnings statements matching the run #114 content ($20 non-taxable, three deductions), plus eight additional deduction rows. Typical statements fit one page at existing readable font sizes. Longer statements may paginate; current and YTD summary blocks must each remain intact. Inspect every rendered page.
- P2: render YTD summary before/after. Company Totals money has dollar signs, commas and two decimals; pay-date basis has a readable value. Counts, hours, dates and spreadsheet numeric values retain their meaning.
- P3: render register before/after. Printed adjustment/field labels have no database IDs; same-name fields retain separate values and readable disambiguation. Currency has grouping separators.

Automated gates: full RSpec with isolated local DB/storage per shard; RuboCop, Brakeman, bundler-audit; frontend typecheck, lint, tests and build. Record final results and evidence below. Browser resizing covers responsive web only; no staging/production or native-device certification.

## Executed acceptance

All four required affected-flow cases passed against the implementation in this PR. This is local web/PDF acceptance, not the staging release retest or accountant certification.

- D1: Chrome at 1440×1000 and 390×844; local admin and synthetic client. Confirmed all six identifying fields, disabled deletion before acknowledgement, keyboard Space toggling, Cancel preservation and checkbox reset. Deleted an 11-employee fixture and a one-employee fixture with two hours. The row disappeared; the success toast named the client, period and pay date. Database reads confirmed the deleted periods/items were absent. A previously approved/calculated fixture returned #417's refusal, kept its hours/items/status, and displayed the server error while leaving the dialog available. The 9-employee/zero-hour path and detail-load failure are covered by component tests.
- P1: inspected the supplied `stub2918-page-2.png` overflow and all pages of synthetic before/after statements. Three and eight additional deduction rows plus $20 non-taxable pay changed from two pages to one. Thirty deductions remain two pages with current and YTD summaries intact. The original 8-point body, 9-point identity text and heading sizes remain unchanged. Only spacing/padding changed; summaries are measured before drawing to avoid splits.
- P2: inspected all 13 pages before/after, with a closer check of Company Totals (pages 8–9). Money now has currency symbols, grouping and two decimals, and `pay_date` prints as “Pay date”. Hours, counts, year and dates keep their types. XLSX regression verifies numeric gross/net cells remain numeric.
- P3: inspected all four register pages before/after. Adjustment/field names no longer carry saved record IDs. Same-name distinct components use occurrence numbers and remain separate columns/totals. Currency grouping is also covered by the large-register and saved-paycheck reconciliation specs.

Evidence root (local, outside Git): `/Users/leonshimizu/Desktop/ShimizuTechnology/output/payroll-final-polish-20261102/`. `before/` and `after/` contain PDFs, extracted text and numbered page PNGs; `*-contact.png` contains full-document visual checks. Browser evidence: `delete-dialog-1440.png`, `delete-dialog-390.png`, `delete-success-390.png`, `delete-refusal-390.png`. `render_fixtures.rb` generates synthetic statements/register/YTD reports transactionally; baseline sources are from `a663d7a5` under `baseline-code/`.

T3 snapshots twice returned “Preview automation snapshot timed out after 15000ms”; Chrome provided the actual interaction and screenshot checks. No native mobile device was tested. Task-created browser tabs and local API/Vite servers were closed after UI QA. Shared resources were preserved.

Automated gate results are in the PR and the evidence logs. The full RSpec manifest covers all 532 spec files in four shards, each using its own `payroll_polish_20261102_shardN` database and `storage-shardN` root. Initial full frontend runs hit unrelated five-second test timeouts; the complete rerun with two workers passed 1,393 tests. Initial backend assertions expecting ungrouped currency were updated without changing saved-money reconciliation expectations. Impeccable reported no findings.
