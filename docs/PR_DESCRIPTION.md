# PR: MoSa Payroll Import — Full-Year 2025 Implementation & Hardening

**Branch:** `feature/mosa-payroll-import`  
**Target:** `main`  
**Type:** Feature + Data Pipeline  
**Author:** Leon Shimizu / Shimizu Technology  
**Date:** 2026-03-09

---

## Summary

Implements a complete automated payroll import pipeline for **MoSa's Joint (company id=475)**, covering all **26 biweekly pay periods for 2025** (PP00–PP25, 2024-12-30 → 2025-12-27). Handles Revel POS PDF parsing, loan/tip Excel ingestion, fuzzy employee name matching, missing employee backfill, and a validation harness that confirmed **zero financial discrepancies across the full year**.

---

## Scope

### New: Import Pipeline

| File | Description |
|------|-------------|
| `api/app/services/payroll_import/import_service.rb` | Orchestrator: parse → match → preview → apply |
| `api/app/services/payroll_import/revel_pdf_parser.rb` | Fixed-column + fallback flexible token parser for Revel POS PDF exports |
| `api/app/services/payroll_import/loan_tip_excel_parser.rb` | Tips and loan deduction parser from MoSa's biweekly Excel template |
| `api/app/services/payroll_import/name_matcher.rb` | Fuzzy name matcher (exact → normalized → fuzzy → alias). Handles `Last, First`, `First Last`, multi-token first names, and targeted aliases |
| `api/app/models/payroll_import_record.rb` | Import session model (`pending → previewed → applied → failed`) |
| `api/app/controllers/api/v1/admin/payroll_imports_controller.rb` | `preview_import` and `apply_import` REST endpoints |

### New: DB Migrations

| Migration | Description |
|-----------|-------------|
| `20260309000001_add_import_fields_to_payroll_items.rb` | Adds `import_source`, `import_id` to `payroll_items` for traceability |
| `20260309000002_create_payroll_imports.rb` | `payroll_imports` table (import session ledger) |
| `20260309044903_change_pay_rate_precision_in_payroll_items.rb` | `pay_rate` → `decimal(10,4)` precision fix for fractional rates |

### New: Scripts & Tooling

| File | Description |
|------|-------------|
| `api/scripts/mosa_full_year_validation.rb` | End-to-end validation across all 26 periods; writes `data/mosa-2025/validation_report.md` |
| `api/scripts/mosa_backfill_employees.rb` | Scans PDFs for unmatched names, creates skeleton employee records safely |
| `scripts/mosa_run.sh` | Entrypoint: `download | validate | backfill | help` |
| `scripts/download_mosa_attachments.py` | Gmail attachment downloader (uses `gog` OAuth) |

### New: Frontend

| File | Description |
|------|-------------|
| `web/src/components/import/ImportModal.tsx` | Import wizard UI: upload PDF + Excel → preview matched employees → confirm apply |
| `web/src/pages/PayPeriodDetail.tsx` | Pay period detail page wired to import modal and import status |
| `web/src/services/api.ts` | API client methods for `previewImport`, `applyImport` |
| `web/src/types/index.ts` | `PayrollImportRecord`, `ImportPreview`, `ImportedRow` types |

### New: Docs

| File | Description |
|------|-------------|
| `docs/ROLLOUT_CHECKLIST.md` | Week-by-week go-live plan with go/no-go gates |
| `docs/RUNBOOK.md` | Operator runbook (daily ops, file naming, common issues) |
| `docs/PR_DESCRIPTION.md` | This file |
| `docs/QB_PARITY_CHECKLIST.md` | QuickBooks parity gap analysis for roadmap planning |
| `data/mosa-2025/validation_report.md` | Final 26-period validation output |
| `data/mosa-2025/mosa_hardening_report_2026-03-09.md` | Hardening pass narrative (backfill + parser precision) |

---

## Validation Results

> **26 / 26 pay periods — zero errors, zero financial discrepancies.**

| Metric | Result |
|--------|--------|
| Periods processed | **26/26** ✅ |
| Periods with errors | 0 ✅ |
| Unmatched employee names | 0 ✅ |
| Parser outlier rows (>200h) | 0 ✅ |
| `gross_diff` across all periods | $0.00 for all 26 ✅ |
| Total employees matched | 1,230 (across all periods) |
| Total gross wages | $1,014,787.04 |
| Total tips | $195,937.00 |
| Total DRT withholding | $37,874.44 |
| Total net pay | $863,062.90 |

**Hours discrepancies** exist for some periods (typically 0–76h) — these are expected, documented, and represent multi-role or pre-backfill employees where DB-computed hours diverge from PDF-reported totals. `gross_diff = $0.00` on all periods confirms financial accuracy.

---

## Known Caveats

1. **Backfilled employees have `pay_rate = 0`.** 35 employees were created with safe defaults so import matching would succeed. HR must update pay rates and personal details before those employees appear on payroll reports with correct figures. Tracked in `ROLLOUT_CHECKLIST.md` (Week 1 action item).

2. **Hours diffs are expected for early periods (PP00–PP03).** PDF-reported hours vs DB-computed hours diverge by 57–70h in early periods due to multi-role employees and pre-backfill gaps. `gross_diff = 0` confirms these are not financial errors.

3. **PP20 was recovered from a mislabeled email.** The Oct 6–19 period email was sent with a "September" subject label. It was located manually and its PDF has been downloaded and validated.

4. **Revel PDF column layout varies.** The parser has a primary fixed-column path and a fallback flexible token-scan path (triggered when any employee parse is implausible — >200h). The 200h threshold matches the validation ceiling and has been verified across all 26 periods with zero regressions.

5. **Gmail OAuth token requires periodic refresh.** If `scripts/mosa_run.sh download` fails with auth errors, run: `GOG_KEYRING_PASSWORD=clawdbot gog gmail auth refresh --account jerry.shimizutechnology@gmail.com --no-input`.

6. **`data/mosa-2025/raw/` is git-ignored.** Raw PDF/Excel files contain PII and are not committed. They live locally at `~/work/cornerstone-payroll/data/mosa-2025/raw/` and must be present on any machine running validation.

---

## Testing Done

| Test | Result |
|------|--------|
| RSpec suite (`bundle exec rspec`) | 53 specs, 0 failures |
| `spec/services/payroll_import/name_matcher_spec.rb` | All name match scenarios: exact, fuzzy, alias, multi-token |
| `spec/services/payroll_import/revel_pdf_parser_spec.rb` | Fixed-column + fallback parser; implausible threshold edge cases |
| Full-year validation (all 26 periods, live PDFs) | 26/26 OK, 0 financial diffs |
| Backfill script idempotency | Re-run produces 0 new records (deduped on `last_name, first_name`) |
| Rollback test | `PayPeriod#payroll_items.destroy_all` cleanly reverts a period |

---

## Rollout Docs

- **Go / No-Go criteria:** `docs/ROLLOUT_CHECKLIST.md` — all automated gates ✅, Cornerstone parallel-run sign-off pending
- **Day-to-day ops:** `docs/RUNBOOK.md` — covers download → validate → backfill → apply cycle
- **Validation evidence:** `data/mosa-2025/validation_report.md` — shareable directly with Cornerstone staff
- **Hardening narrative:** `data/mosa-2025/mosa_hardening_report_2026-03-09.md`

---

## Migrations

Migrations are non-destructive and additive. Safe to run on staging before main.

```bash
cd api
bundle exec rails db:migrate
```

Schema change: `pay_rate` precision upgraded from default to `decimal(10,4)`. Any existing pay rate values are preserved — only storage precision increases.

---

## How to Review

1. Start with `docs/ROLLOUT_CHECKLIST.md` for overall context.
2. Review `api/app/services/payroll_import/` — this is the core logic.
3. Check `data/mosa-2025/validation_report.md` for validation evidence.
4. Run tests: `cd api && bundle exec rspec spec/services/payroll_import/`
5. Comment `@greptile` on the PR for AI code review.

---

*Prepared by Shimizu Technology — 2026-03-09*
