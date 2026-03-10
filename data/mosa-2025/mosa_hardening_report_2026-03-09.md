# MoSa 2025 Hardening Pass Report

**Date:** 2026-03-09 (ChST)
**Repo:** `~/work/cornerstone-payroll`
**Scope:** Backfill unmatched 2025 employees + harden Revel PDF parser + verify 2025 pay-period completeness

## What was changed

### 1) Backfill strategy + implementation

Implemented a dedicated script:
- `api/scripts/mosa_backfill_employees.rb`

Strategy:
1. Parse all Revel payroll PDFs in `data/mosa-2025/raw/payroll_*.pdf`.
2. Identify unmatched names using `PayrollImport::NameMatcher` against active MoSa employees.
3. Normalize names as `Last, First` and dedupe by `(last_name, first_name)`.
4. Create missing employee records with safe defaults (`hourly`, `biweekly`, `single`, `allowances=0`, `pay_rate=0`) so import can set realistic rate from PDF on apply.

Execution result:
- Unique unmatched names discovered: **35**
- Missing employee records created: **35**
- Errors: **0**

Also hardened `NameMatcher` (`api/app/services/payroll_import/name_matcher.rb`):
- Supports full first-name segments (e.g., `Young Paul`) instead of only first token.
- Added normalization (punctuation/case cleanup) before exact/fuzzy matching.
- Added targeted aliases for common drift (`Kyle A.`/`Kyle Richard`, `Jayden M.`, `Maria Carmella`).

### 2) Revel parser hardening for layout drift/outliers

Updated `api/app/services/payroll_import/revel_pdf_parser.rb`:
- Kept fixed-column parse as primary path.
- Added fallback parser that extracts right-aligned numeric tokens (`-` / decimal values) when fixed parse is implausible.
- Trigger fallback when fixed parse appears corrupted (blank employee, impossible hours, pay-with-zero-hours condition).

This directly addresses prior “shifted column” rows producing 300–1300h outliers.

---

## Validation rerun (before vs after)

Validation command used both times:
- `bundle exec rails runner scripts/mosa_full_year_validation.rb`

### Baseline (before hardening/backfill)
- Employees in MoSa: **46**
- Periods processed: **25/25**
- Total unmatched names: **263**
- Periods with unmatched names: **24/25**
- Parser outlier periods: **7/25**
- Parser outlier rows: **59**

### After hardening + backfill
- Employees in MoSa: **81** (46 + 35 backfilled)
- Periods processed: **25/25**
- Total unmatched names: **0** ✅
- Periods with unmatched names: **0/25** ✅
- Parser outlier periods: **1/25**
- Parser outlier rows: **1** (single row at 224.41h in PP09)

### Improvement summary
- Unmatched names: **263 → 0** (**-263, 100% reduction**)
- Unmatched periods: **24 → 0**
- Parser outlier periods: **7 → 1** (**-85.7%**)
- Parser outlier rows: **59 → 1** (**-98.3%**)

---

## 2025 pay-period count: 25 vs 26 (evidence)

### Evidence-backed conclusion
The imported MoSa 2025 dataset contains **25 pay periods**, not 26, with one missing biweekly window.

Reasoning:
- 2025 has 52 weeks; biweekly schedules are usually 26 periods.
- Dataset starts at period covering `2024-12-30 – 2025-01-11` and ends at `2025-12-15 – 2025-12-27`.
- There is a missing interval between PP19 and PP20.

### Date-range table (from validation script period config)

| Label | Start | End |
|---|---|---|
| PP00 | 2024-12-30 | 2025-01-11 |
| PP01 | 2025-01-13 | 2025-01-25 |
| PP02 | 2025-01-27 | 2025-02-08 |
| PP03 | 2025-02-10 | 2025-02-22 |
| PP04 | 2025-02-23 | 2025-03-07 |
| PP05 | 2025-03-10 | 2025-03-22 |
| PP06 | 2025-03-24 | 2025-04-05 |
| PP07 | 2025-04-07 | 2025-04-19 |
| PP08 | 2025-04-21 | 2025-05-03 |
| PP09 | 2025-05-05 | 2025-05-17 |
| PP10 | 2025-05-19 | 2025-05-30 |
| PP11 | 2025-06-02 | 2025-06-14 |
| PP12 | 2025-06-16 | 2025-06-28 |
| PP13 | 2025-06-30 | 2025-07-12 |
| PP14 | 2025-07-14 | 2025-07-26 |
| PP15 | 2025-07-28 | 2025-08-08 |
| PP16 | 2025-08-11 | 2025-08-22 |
| PP17 | 2025-08-25 | 2025-09-06 |
| PP18 | 2025-09-08 | 2025-09-20 |
| PP19 | 2025-09-22 | 2025-10-04 |
| **GAP** | **2025-10-05** | **2025-10-19** |
| PP20 | 2025-10-20 | 2025-11-01 |
| PP21 | 2025-11-03 | 2025-11-14 |
| PP22 | 2025-11-17 | 2025-11-29 |
| PP23 | 2025-12-01 | 2025-12-13 |
| PP24 | 2025-12-15 | 2025-12-27 |

Missing gap identified:
- **2025-10-05 to 2025-10-19** (one biweekly cycle)

---

## Remaining gaps / risks

1. ~~**One residual parser outlier row** remains in PP09 (`Thomas, Natalie` 224.41h).~~ **Resolved — see Final Precision Pass below.**
2. Backfilled employees were created with minimal defaults and `pay_rate=0` for safe import bootstrap. This is intentional for import matching, but HR master data should be enriched later if these people are still active.
3. Validation script still redefines `MAX_REALISTIC_HOURS` inside loop (warning noise only).

## Confidence

**High** for primary objectives:
- Backfill completed and verified by rerun.
- Parser hardening materially improved extraction robustness.
- 25-vs-26 conclusion is evidence-backed with explicit date table and gap.

**High** for parser accuracy — zero outliers after final precision pass.

---

## Final Precision Pass (2026-03-09)

**Goal:** Eliminate the last parser outlier (Thomas, Natalie 224.41h in PP09) and achieve zero outliers across all 25 periods.

### Root cause

PP09's Thomas, Natalie PDF entry spans two lines with the name split:
- Line N: `Thomas,  ... 24.26  ...  224.41  ...  24.26  224.41  ...` (numbers on name-line)
- Line N+1: `Natalie` (name continuation, no numbers)

The multi-line merge logic correctly combined the name. However, fixed-column parsing on the merged line read position `220..239` as `"224.41"` (the **regular_pay** value, not total_hours), due to this PDF's column layout being ~20 characters narrower than normal. The `implausible_fixed_parse?` threshold was `> 240.0` — so 224.41 didn't trigger the fallback. The validation script's `MAX_REALISTIC_HOURS = 200.0` then caught and flagged it as an outlier.

### Fix applied

**File:** `api/app/services/payroll_import/revel_pdf_parser.rb`

Changed `implausible_fixed_parse?` threshold from `> 240.0` to `> 200.0` to match the validation script's ceiling. This aligns both guards and causes the flexible token-scan fallback to trigger for Thomas, Natalie's compressed-layout line.

The flexible parser correctly extracts:
- `regular_hours = 24.26`, `regular_pay = 224.41`
- `total_hours = 24.26`, `total_pay = 224.41`
- Effective hourly rate ≈ $9.25/h (plausible)

Threshold rationale: 200h = 14 days × ~14.3h/day — a realistic hard ceiling for any biweekly restaurant employee.

### After fix — full 25-period validation

| Metric | Before (hardening pass) | After (precision pass) |
|--------|------------------------|------------------------|
| Parser outlier periods | 1/25 | **0/25** ✅ |
| Parser outlier rows | 1 | **0** ✅ |
| Unmatched names | 0 | 0 (unchanged) |
| Periods OK | 25/25 | 25/25 (unchanged) |
| Hours diffs | unchanged | PP09 now 0.02h (was 6.02h) ✅ |
| Regressions | — | None detected |

PP09 hours diff improved from 6.02h → 0.02h (Thomas, Natalie's 24.26h correctly included in comparison).

### Confidence

**High.** Fix is minimal (1-line threshold change), deterministic, and verified clean across all 25 periods with zero regressions.
