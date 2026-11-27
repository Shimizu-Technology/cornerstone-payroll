# Form 941, Check Printing, and Operations Reference

Production releases are governed by [PRODUCTION_READINESS_CHECKLIST.md](PRODUCTION_READINESS_CHECKLIST.md). Run its automated configuration gate and complete the manual evidence checklist before any payroll or filing workload is released.

---

## Federal Form 941 Quarterly Worksheet for Guam Employers (CPR-59)

### Overview

This report generates a structured preparation worksheet for the standard federal Form 941. Form 941-SS was discontinued after 2023; Guam employers now file Form 941 with the IRS and generally leave lines 2 and 3 blank unless they have employees subject to U.S. income-tax withholding. Guam wage withholding is handled separately through Form 500 and W-1 with Guam DRT.

> **Legacy route note:** The API route retains `form_941_gu` for backward compatibility. It does not represent a separate current form named "941-GU."

**Endpoint:**
```
GET /api/v1/admin/reports/form_941_gu?year=2025&quarter=1
```

**Parameters:**
| Param | Type | Required | Notes |
|-------|------|----------|-------|
| `year` | integer | No (defaults to current year) | Tax year |
| `quarter` | integer | **Yes** | 1, 2, 3, or 4 |

**Example curl:**
```bash
curl -H "Authorization: Bearer <token>" \
  "https://api.cornerstone.example.com/api/v1/admin/reports/form_941_gu?year=2025&quarter=1"
```

### Response Structure

```json
{
  "report": {
    "meta": { "report_type": "form_941_gu", "year": 2025, "quarter": 1, ... },
    "employer_info": { "name": "...", "ein": "...", "address": "..." },
    "lines": {
      "line1_employee_count": 12,
      "line2_wages_tips_other": null,
      "line3_fit_withheld": null,
      "line5a_ss_wages": 150000.00,
      "line5a_ss_combined_tax": 18600.00,
      "line5b_ss_tips": 0.00,
      "line5b_ss_tips_combined_tax": 0.00,
      "line5c_medicare_wages": 150000.00,
      "line5c_medicare_combined_tax": 4350.00,
      "line5d_add_medicare_wages": 0.00,
      "line5d_add_medicare_tax": 0.00,
      "line5e_total_ss_medicare": 22950.00,
      "line6_total_taxes_before_adj": 22950.00,
      "line7_adj_fractions_cents": null,
      "line8_adj_sick_pay": null,
      "line9_adj_tips_group_life": null,
      "line10_total_taxes_after_adj": 22950.00,
      "line11_nonrefundable_credits": null,
      "line12_total_after_credits": 22950.00,
      "line13_total_deposits": null,
      "line14_balance_due_or_overpayment": null
    },
    "tax_detail": { "ss_employee": ..., "ss_employer": ..., ... },
    "monthly_liability": [
      { "month": "January 2025", "total_liability": 13816.67 },
      ...
    ]
  }
}
```

### Placeholder Fields

This example represents a typical Guam employer without wages subject to U.S. income-tax withholding, so lines 2 and 3 are intentionally blank. Fields returning `null` require review and, when applicable, **manual entry before filing**:

| Line | Field | Notes |
|------|-------|-------|
| 2–3 | `line2_wages_tips_other`, `line3_fit_withheld` | Generally blank for Guam employers; complete only when employees are subject to U.S. income-tax withholding |
| 7 | `line7_adj_fractions_cents` | Rounding adjustment; may be calculated when the available payroll detail supports it, but must be reviewed |
| 8 | `line8_adj_sick_pay` | Sick pay from third-party payers; not tracked in payroll_items |
| 9 | `line9_adj_tips_group_life` | Group-term life > $50K; not tracked |
| 11 | `line11_nonrefundable_credits` | Small business payroll tax credit |
| 13 | `line13_total_deposits` | Verify federal deposits against EFTPS records |
| 14 | `line14_balance_due_or_overpayment` | Derived from 12 - 13 |

### Filing Workflow

1. **Generate report** via the API for the target year/quarter.
2. **Review `meta.caveats`** — read all caveats before filing.
3. **Verify pay period count** — `meta.pay_periods_included` should match expected payrolls.
4. **Complete placeholder lines manually** — consult your accountant for lines 7–14.
5. **Cross-reference monthly_liability** — use for Schedule B (semiweekly depositor worksheet).
6. **File** the completed standard Form 941 with the IRS using the current official instructions. File Guam withholding through the separate Guam DRT Form 500/W-1 workflow.

### Key Caveats

- **Only committed pay periods** (status = "committed") with `pay_date` in the quarter are included.
- **SS wages and tips (lines 5a/5b)** use committed taxable bases when available. Legacy rows reconstruct from stored taxes/gross and must be reconciled before filing; verify the filing-year wage base for high earners.
- **Additional Medicare Tax (line 5d)** uses year-to-date wages in the current implementation. Reconcile prior-quarter and imported historical wages before relying on it for a filing.
- **Tips (line 5b)** use `reported_tips` from payroll_items. If tip pools are allocated differently, reconcile before filing.
- **Adjustments (lines 7–9)** are not all derived from payroll data. Review line 7 and manually complete any applicable line 8 or 9 adjustment before filing.

### Service Location

```
api/app/services/form_941_gu_aggregator.rb
```

### Tests

```bash
cd api
bundle exec rspec spec/services/form_941_gu_aggregator_spec.rb spec/requests/api/v1/admin/reports_spec.rb
```

---

## Check Printing (CPR-66)

### Overview

Cornerstone Payroll generates 3-part check PDFs for pre-printed check stock (letter size, 8.5" × 11").
- **Bottom-check** layout (default): Employee stub (top) → Employer stub (middle) → Check face (bottom).
- **Top-check** layout: reversed.

Check numbers are assigned automatically when a pay period is committed.

### Operator Workflow

#### Normal Print Run

1. Run and commit a payroll — check numbers are auto-assigned sequentially.
2. Navigate to **Pay Period detail** → **Checks** section.
3. Click **"Download All Checks PDF"** → combined PDF, one page per employee.
4. Load pre-printed check stock into printer (verify orientation with alignment test first).
5. Print the PDF.
6. Click **"Mark All Printed"** in the UI → records print events in audit trail.

#### Alignment Calibration (first run on new stock)

1. Go to **Settings → Check Settings**.
2. Click **"Download Alignment Test PDF"**.
3. Print on **plain paper**.
4. Hold the printout behind a sheet of check stock and hold to light.
5. Verify all labeled boxes (PAYEE, AMOUNT BOX, SIGNATURE LINE, etc.) align with pre-printed fields.
6. If not aligned, adjust X/Y offsets:
   - **X Offset**: positive shifts all fields RIGHT (inches). Try 0.05 increments.
   - **Y Offset**: positive shifts all fields UP (inches). Try 0.05 increments.
7. Save settings, regenerate alignment test, repeat until aligned.
8. Print final test on plain paper + compare to live stock before using real checks.

**Typical offset range:** ±0.25 inches. Values outside ±0.5" indicate a stock measurement issue.

#### Void a Check

Use when a physical check is damaged, destroyed, or the payee has changed.

1. On the Checks panel, click **"Void"** next to the check.
2. Enter a written reason (required, ≥ 10 characters).
   - e.g., "Paper jam — check damaged during print run"
   - e.g., "Check lost in mail — employee confirmed not received"
3. Confirm. The check is recorded as voided in the audit log.

**The payroll obligation remains.** The employee still gets paid — issue a reprint.

#### Reprint a Check

Use when a physical check was damaged, lost, or misprinted.

1. On the Checks panel, click **"Reprint"** next to the check.
2. Optionally enter a reason (e.g., "Check lost in mail").
3. Confirm. The old check number is audit-logged as voided; a new number is assigned.
4. Download the new check PDF and print on fresh stock.
5. Mark as printed after physical printing.

**Safety:** The reprint uses the same net pay amount. The next sequential company check number is reserved.

### Configuration (Rails console)

```ruby
# View current settings for a company
company = Company.find_by(name: "Example Company")
puts company.next_check_number    # e.g., 1042
puts company.check_stock_type     # "bottom_check" or "top_check"
puts company.check_offset_x       # e.g., 0.05 (inches)
puts company.check_offset_y       # e.g., -0.025

# Manually set next check number (use only if no checks issued this year)
company.update!(next_check_number: 2000)

# Preview a check without printing
item = PayrollItem.includes(:employee, :pay_period).find(123)
gen = CheckGenerator.new(item)
File.write('/tmp/preview_check.pdf', gen.generate)
```

### Audit Trail

All check events are stored in the `check_events` table:

```ruby
# All events for a specific check number
CheckEvent.where(check_number: "1042").order(:created_at).each do |e|
  puts "#{e.created_at.strftime('%Y-%m-%d %H:%M')} | #{e.event_type} | #{e.reason}"
end

# All events for a pay period
PayrollItem
  .includes(:check_events, :employee)
  .joins(:pay_period)
  .where(pay_periods: { id: 7 })
  .each do |item|
    puts "#{item.employee.full_name} | Check #{item.check_number} | #{item.check_status}"
    item.check_events.order(:created_at).each do |e|
      puts "  → #{e.event_type} at #{e.created_at}"
    end
  end
```

### Check Stock Notes

- **Stock brand:** Confirm with the client before the first print run.
- **Starting check number:** Set via Settings → Check Settings or Rails console.
- **Bank info:** Set via Settings → Check Settings (displayed on check face).
- **MICR line:** Pre-printed on stock — Cornerstone does NOT generate MICR.

### Tests

```bash
cd api
bundle exec rspec spec/lib/number_to_words_spec.rb \
                  spec/services/check_generator_spec.rb \
                  spec/models/payroll_item_check_spec.rb \
                  spec/models/company_check_spec.rb \
                  spec/requests/api/v1/admin/checks_spec.rb
```

---

## Office Document Preview Deployment Note

Client document previews support two different paths:

- **PDF and image files** preview directly in the app and are expected to work in production as-is.
- **Office-style files** such as `.doc`, `.docx`, `.xls`, `.xlsx`, `.csv`, and `.txt` rely on backend preview generation that converts the source file into a PDF before the in-app preview is shown.

### Current Production Limitation

The office preview generator depends on the following backend tools:

- `LibreOffice` / `soffice`
- `python3`
- Python package `openpyxl`

The current production deployment uses:

- **Frontend:** Netlify
- **Backend:** Render native Ruby/Rails service

Netlify does **not** need any special setup for this feature.

The backend is the limiting factor. Render's native Ruby service is fine for the app overall, but office preview generation may not work in production unless the backend runtime has LibreOffice installed and available on `PATH` (or provided through `LIBREOFFICE_BIN`).

### Recommended Future Production Setup

Preferred option:

1. Keep the main Rails web service on Render native Ruby/Rails.
2. Add a **separate Docker-based worker/service** dedicated to office preview generation.
3. Install the required packages in that worker image:
   - LibreOffice
   - Python 3
   - `openpyxl`
4. Point preview jobs to that worker environment.

Alternative option:

1. Migrate the backend service itself to a Docker deployment later.
2. Install the same preview dependencies in the backend image.

The separate worker approach is preferred because it avoids changing the existing live Rails web service type just to support office-file previews.

### Implementation Notes

- The preview generator lives in `api/app/services/client_document_preview_generator.rb`.
- If LibreOffice is installed in a non-standard location, set `LIBREOFFICE_BIN`.
- Any Render worker or background job service that runs preview generation must have the same dependency set as the process handling the job.

### OCR Model Default

Timecard OCR defaults to `google/gemini-3.1-pro-preview` through OpenRouter unless `OPENROUTER_MODEL` is explicitly set in the environment. This keeps the current OCR flow pointed at the strongest verified multimodal model for the existing image-based extraction pipeline without changing the surrounding OpenRouter integration.
