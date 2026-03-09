# MoSa Payroll Import — Operator Runbook

## Overview

This runbook covers day-to-day operation of the MoSa payroll import pipeline for Cornerstone Tax.

| Item | Value |
|------|-------|
| Company | MoSa's Joint (id=475) |
| Data location | `data/mosa-2025/raw/` |
| Validation report | `data/mosa-2025/validation_report.md` |
| Manifest | `data/mosa-2025/manifest.json` |
| Entrypoint | `scripts/mosa_run.sh` |

---

## Quick Start

```bash
cd ~/work/cornerstone-payroll

# Run full validation (safe, read-only)
scripts/mosa_run.sh validate

# Download new Gmail attachments + validate
scripts/mosa_run.sh download
scripts/mosa_run.sh validate

# See all commands
scripts/mosa_run.sh help
```

---

## Pipeline Steps

### Step 1 — Download Attachments (when new period arrives)

```bash
scripts/mosa_run.sh download
```

What it does:
- Reads `scripts/download_mosa_attachments.py`
- Fetches all known message IDs from Gmail (jerry.shimizutechnology@gmail.com)
- Saves PDFs and Excel files to `data/mosa-2025/raw/`
- Updates `data/mosa-2025/manifest.json`

**When to run:** When MoSa's accountant sends a new payroll period email.

### Step 2 — Add New Period (for each new pay period)

1. Get the new message ID from Gmail:
   ```bash
   GOG_KEYRING_PASSWORD=clawdbot gog gmail search "payroll mosa" \
     --account jerry.shimizutechnology@gmail.com --no-input
   ```

2. Add the message ID to `scripts/download_mosa_attachments.py` MESSAGES list.

3. Add a new entry to `PAY_PERIODS` in `api/scripts/mosa_full_year_validation.rb`:
   ```ruby
   {
     label: "PP26",
     pdf: "payroll_2026-01-XX_00-00_to_2026-01-XX_23-59.pdf",
     excel: "pp26_2026-01-XX_to_2026-01-XX_loan_tip.xlsx",
     start_date: "2026-01-XX",
     end_date: "2026-01-XX"
   }
   ```

4. Rename the downloaded Excel attachment to match the `pp26_...` convention.

5. Re-run validation:
   ```bash
   scripts/mosa_run.sh validate
   ```

### Step 3 — Backfill Employees (when new names appear)

```bash
scripts/mosa_run.sh backfill
```

This runs `api/scripts/mosa_backfill_employees.rb` which:
- Scans all PDFs for employee names not in the DB
- Creates skeleton employee records (safe defaults, pay_rate=0)
- Reports count of new records created

**After backfill:** HR should update pay rates and personal details for new employees.

### Step 4 — Validate

```bash
scripts/mosa_run.sh validate
```

Reads all 26 (or more) pay period PDFs + Excel files, runs them through the import engine, and writes `data/mosa-2025/validation_report.md`.

**Healthy output:**
```
Periods OK: 26/26
Total unmatched names: 0
Discrepancies: 14 period(s)  # hours-only diffs, gross_diff=0 for all — NORMAL
```

**Hours discrepancies are expected** for certain periods. They result from multi-period employees or employees excluded from the Excel import. The key metric is `gross_diff=0.0` for all periods — that confirms financial accuracy.

---

## Interpreting the Validation Report

| Field | Good value | Needs attention |
|-------|-----------|-----------------|
| Periods OK | 26/26 | Any period with "error" or "skip" |
| Total unmatched names | 0 | Any > 0 → run backfill |
| Parser outlier rows | 0 | Any > 0 → check PDF layout |
| gross_diff | 0.0 | Any non-zero → investigate |
| hours_diff | 0–80h for early periods | >200h in any period → parser issue |

**Hours diffs explained:**  
PP00–PP03 show 57–70h diffs because these early periods had employees with names slightly different from DB records (pre-backfill). After hardening, all 35 were matched but the comparison uses DB-computed hours vs PDF-reported hours which can diverge for multi-role employees. Financial totals (gross_diff=0) confirm correctness.

---

## Common Issues

### "File not found" for a PDF

The PDF wasn't downloaded or was renamed.
```bash
ls data/mosa-2025/raw/payroll_*.pdf | sort
```
Check the filename exactly matches what's in the `PAY_PERIODS` config.

### "Company not found: MoSa's Joint"

The Rails environment doesn't have MoSa's Joint in the Company table.
```bash
cd api && rails runner "puts Company.pluck(:name)"
```
Make sure you're running against the correct environment (staging/production).

### New employee shows as "unmatched"

Run: `scripts/mosa_run.sh backfill`  
Then update the new employee's pay rate and personal info in the admin UI.

### Parser warning: "implausible hours"

A PDF layout has drifted from the column spec. The fallback flexible parser should handle it. Check:
```bash
cd api && rails runner "puts PayrollImport::RevelPdfParser.parse('../data/mosa-2025/raw/YOUR_FILE.pdf').inspect"
```

If the flexible parser also fails, check the PDF format — Revel may have changed their export template.

---

## File Naming Convention

| File type | Pattern | Example |
|-----------|---------|---------|
| Payroll PDF | `payroll_YYYY-MM-DD_00-00_to_YYYY-MM-DD_23-59.pdf` | `payroll_2025-10-06_00-00_to_2025-10-19_23-59.pdf` |
| Loan/Tip Excel | `ppXX_YYYY-MM-DD_to_YYYY-MM-DD_loan_tip.xlsx` | `pp20_2025-10-06_to_2025-10-19_loan_tip.xlsx` |

Periods are numbered sequentially PP00–PP25 for 2025 (26 total).

---

## Environment Setup

```bash
# Ruby (managed by rbenv)
export PATH="$HOME/.rbenv/shims:$PATH"
ruby --version  # Should be 3.3.x

# Install deps
cd ~/work/cornerstone-payroll/api && bundle install

# Configure Gmail access
GOG_KEYRING_PASSWORD=clawdbot gog gmail search "test" \
  --account jerry.shimizutechnology@gmail.com --no-input
```

---

## Contacts

| Role | Name | Notes |
|------|------|-------|
| Cornerstone CEO | Dafne Mansapit Shimizu (dmshimizucpa@gmail.com) | Forwards MoSa payroll emails |
| MoSa accountant | — | Sends original payroll to Cornerstone |
| Developer | Leon / Shimizu Technology | System owner |

---

*Last updated: 2026-03-09*
