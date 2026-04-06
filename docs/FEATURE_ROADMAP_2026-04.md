# Feature Roadmap — April 2026

Planned features for the next development cycle. Audited against codebase on 2026-04-06.

---

## Feature 1: Form 500 Link in Payroll Workflow

**Status:** 🔲 NOT STARTED  
**Priority:** High (quick win)  
**Effort:** Small (1-2 hours)  
**Branch:** `feature/form500-and-transmittal-persistence`

### Context

Cornerstone processes payroll for Guam-based businesses. Every FIT (Federal Income Tax) deposit requires filing **Guam DRT Form 500** — a depository receipt for income tax withheld. Currently there's no link to this form anywhere in the app, so users have to navigate to the DRT site manually every pay period.

### Links

- **DRT Forms Page:** https://www.govguamdocs.com/revtax/index_revtax.htm
- **Form 500 (PDF):** https://www.govguamdocs.com/revtax/docs/F500winstructions_201102.pdf

### Implementation Plan

1. **NonEmployeeChecksPanel** — When a check has `check_type: "tax_deposit"`, show a "Form 500" link/button that opens the Form 500 PDF in a new tab.
2. **PayPeriodDetail** (committed state) — Add an info callout in the tax deposit area linking to Form 500.
3. **TransmittalEditorModal** — Add a "Guam DRT Resources" section with links to Form 500 and the DRT forms page.
4. Store URLs in a shared constants file (`web/src/lib/constants.ts`) so they're easy to update if the DRT changes their site.

### Files to Touch

- `web/src/lib/constants.ts` (new — DRT URLs)
- `web/src/components/checks/NonEmployeeChecksPanel.tsx`
- `web/src/pages/PayPeriodDetail.tsx`
- `web/src/components/reports/ReportsDownloadPanel.tsx`

---

## Feature 2: Save Transmittal State

**Status:** 🔲 NOT STARTED  
**Priority:** High  
**Effort:** Medium (4-6 hours)  
**Branch:** `feature/form500-and-transmittal-persistence`

### Context

The transmittal log is currently generated entirely on-the-fly. If a user configures check numbers, notes, preparer name, and report list in the editor modal, generates the PDF, and later needs to reprint — they have to re-enter everything from scratch. This is error-prone and wastes time.

### Implementation Plan

#### Backend

1. **Migration:** Create `transmittals` table:
   - `pay_period_id` (FK, unique index — one transmittal per pay period)
   - `preparer_name` (string)
   - `notes` (jsonb — array of strings)
   - `report_list` (jsonb — array of strings)
   - `check_number_first` (string)
   - `check_number_last` (string)
   - `non_employee_check_numbers` (jsonb — `{check_id: "number"}`)
   - `generated_at` (datetime)
   - `created_by_id` (FK to users)
   - `updated_by_id` (FK to users)
   - `timestamps`

2. **Model:** `Transmittal` with `belongs_to :pay_period` and validations.

3. **Controller changes:**
   - When generating a transmittal PDF (`transmittal_log_pdf` or `full_print_package_pdf`), upsert the `Transmittal` record with the options used.
   - Modify `transmittal_preview` to also return saved transmittal state if one exists.
   - New endpoint `GET /transmittals/:pay_period_id` to retrieve saved state directly.

#### Frontend

4. **TransmittalEditorModal:**
   - On open, check for saved transmittal state from the preview endpoint.
   - If saved state exists, pre-populate all fields from it (instead of defaults).
   - Show "Last generated: [date] by [user]" indicator.
   - After generating, the backend auto-saves — no extra save button needed.

5. **ReportsDownloadPanel:**
   - Add a "Reprint Last Transmittal" button that re-generates using saved options (no modal needed).

### Files to Touch

- `api/db/migrate/XXXXXX_create_transmittals.rb` (new)
- `api/app/models/transmittal.rb` (new)
- `api/app/controllers/api/v1/admin/reports_controller.rb`
- `api/config/routes.rb`
- `web/src/services/api.ts`
- `web/src/components/reports/ReportsDownloadPanel.tsx`

---

## Feature 3: Employee Bulk Import

**Status:** 🔲 NOT STARTED  
**Priority:** Critical (MoSa onboarding — 50+ employees)  
**Effort:** Medium-Large (6-10 hours)  
**Branch:** `feature/employee-bulk-import`

### Context

When onboarding a new client like MoSa, all their employees (50+) need to be entered into the system. Currently this is one-by-one through the employee form. This is a major bottleneck for client rollout.

### Implementation Plan — Phase A: CSV/Spreadsheet Upload

#### Backend

1. **Downloadable template:** Generate a CSV/Excel template with all employee fields:
   - Required: `first_name`, `last_name`, `hire_date`, `pay_rate`, `employment_type`, `pay_frequency`
   - Tax/W-4: `filing_status`, `allowances`, `additional_withholding`, `w4_step2_multiple_jobs`, `w4_dependent_credit`, `w4_step4a_other_income`, `w4_step4b_deductions`
   - Optional: `ssn`, `date_of_birth`, `email`, `phone`, `address_line1/2`, `city`, `state`, `zip`, `department` (name match), `middle_name`

2. **New `EmployeeBulkImportsController`:**
   - `POST /employee_bulk_imports/preview` — Upload CSV/Excel, parse rows, validate each, return preview with row-by-row status (valid/invalid/duplicate detection by name+SSN).
   - `POST /employee_bulk_imports/apply` — Create all valid employees in a transaction, return results (created count, error rows).
   - `GET /employee_bulk_imports/template` — Download blank template file.

3. **Service:** `EmployeeBulkImport::ImportService` — parsing (reuse `roo` gem for Excel), validation, duplicate detection, bulk creation.

#### Frontend

4. **New `EmployeeBulkImportModal`** (or dedicated page at `/employees/import`):
   - Step 1: Download template link + file upload (CSV or Excel)
   - Step 2: Preview table — each row shows parsed data, validation status, error messages
   - Step 3: Confirm & import — progress indicator, results summary
   - Step 4: Done — link to employee list, count of created employees

5. **EmployeeList page:** Add "Bulk Import" button next to "Add Employee".

### Files to Touch

- `api/app/controllers/api/v1/admin/employee_bulk_imports_controller.rb` (new)
- `api/app/services/employee_bulk_import/import_service.rb` (new)
- `api/config/routes.rb`
- `web/src/components/employees/EmployeeBulkImportModal.tsx` (new)
- `web/src/pages/employees/EmployeeList.tsx`
- `web/src/services/api.ts`

### Future Phases

- **Phase B:** Document OCR — upload W-4/I-9 forms, extract employee data via OCR, pre-populate fields for review.
- **Phase C:** Payroll system import — import from QuickBooks, ADP, etc. export formats.

---

## Feature 4: Payroll Reminders

**Status:** 🔲 NOT STARTED  
**Priority:** Medium  
**Effort:** Medium (6-8 hours)  
**Branch:** `feature/payroll-reminders`

### Context

Currently there's no reminder system for processing payroll. Leon (and eventually Cornerstone clients) need to remember when to process payroll and pay employees based on each company's pay frequency. Forgetting or being late on payroll is a serious issue.

### Design Decisions

- **Email-only** for now (via Resend, which is already integrated for user invites).
- **Per-company** with configurable recipients (email addresses).
- **Frequency derived from company `pay_frequency`:**
  - `weekly` — reminder X days before every week's pay date
  - `biweekly` — reminder X days before every 2 weeks' pay date
  - `semimonthly` — reminder X days before the 15th and last day of month (or configured dates)
  - `monthly` — reminder X days before the monthly pay date

### Implementation Plan

#### Backend

1. **Migration:** Create `payroll_reminder_configs` table:
   - `company_id` (FK, unique — one config per company)
   - `enabled` (boolean, default false)
   - `days_before` (integer, default 3 — how many days before pay date to send reminder)
   - `recipients` (jsonb — array of email addresses)
   - `pay_day_of_week` (integer, for weekly/biweekly — 0=Sun through 6=Sat)
   - `semimonthly_first_day` (integer, default 15)
   - `semimonthly_second_day` (integer, default 0 = last day of month)
   - `monthly_day` (integer, default 1)
   - `last_reminder_sent_at` (datetime)
   - `timestamps`

2. **Model:** `PayrollReminderConfig` with `belongs_to :company`.

3. **Job:** `PayrollReminderJob` — runs daily via Solid Queue recurring schedule:
   - For each company with `enabled: true`, calculate the next upcoming pay date based on frequency and config.
   - If today is within `days_before` of that pay date and no reminder was sent for this cycle, send email to all recipients.
   - Update `last_reminder_sent_at`.

4. **Mailer:** `PayrollReminderMailer` — sends via Resend with company name, pay period dates, pay date, and a link to the app's pay periods page.

5. **Controller:** `PayrollReminderConfigsController` — CRUD for the config, nested under company or as admin endpoint.

#### Frontend

6. **Reminder settings UI** — accessible from company settings or a new "Reminders" section:
   - Enable/disable toggle
   - Days before pay date (dropdown: 1-7)
   - Recipients list (add/remove email addresses)
   - Pay schedule configuration (day of week for weekly/biweekly, dates for semimonthly/monthly)
   - "Send Test Reminder" button

### Files to Touch

- `api/db/migrate/XXXXXX_create_payroll_reminder_configs.rb` (new)
- `api/app/models/payroll_reminder_config.rb` (new)
- `api/app/jobs/payroll_reminder_job.rb` (new)
- `api/app/mailers/payroll_reminder_mailer.rb` (new)
- `api/app/controllers/api/v1/admin/payroll_reminder_configs_controller.rb` (new)
- `api/config/recurring.yml` (add daily schedule)
- `api/config/routes.rb`
- `web/src/pages/PayrollReminders.tsx` (new) or section in company settings
- `web/src/services/api.ts`

---

## Execution Order

| Order | Feature | Branch |
|-------|---------|--------|
| 1st | Form 500 Link | `feature/form500-and-transmittal-persistence` |
| 2nd | Save Transmittal State | `feature/form500-and-transmittal-persistence` |
| 3rd | Employee Bulk Import | `feature/employee-bulk-import` |
| 4th | Payroll Reminders | `feature/payroll-reminders` |

---

## Notes

- MoSa is about to test the application on prod. The MoSa/Revel payroll import needs to be verified working before their onboarding.
- Employee bulk import (Feature 3) is critical path for MoSa — they have 50+ employees to enter.
- Form 500 is Guam-specific (DRT Depository Receipt for Income Tax Withheld). If we onboard non-Guam clients, this should be configurable per jurisdiction.
