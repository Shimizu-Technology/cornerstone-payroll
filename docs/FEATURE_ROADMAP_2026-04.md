# Feature Roadmap — April 2026

Planned features for the April 2026 development cycle. Audited against codebase on 2026-04-15.

---

## Feature 1: Form 500 Link in Payroll Workflow

**Status:** ✅ DONE  
**Priority:** High (quick win)  
**Effort:** Small (1-2 hours)  
**Merged:** `main`

### What was done

- `DRT` constants file created at `web/src/lib/constants.ts` with Form 500 PDF and DRT Forms page URLs.
- **NonEmployeeChecksPanel** — Banner callout when any `tax_deposit` check exists, plus per-row Form 500 link on each tax deposit check.
- **TransmittalEditorModal** — "Guam DRT Resources" section with links to Form 500 and DRT forms page.
- All URLs centralized in `web/src/lib/constants.ts`.

---

## Feature 2: Save Transmittal State

**Status:** ✅ DONE  
**Priority:** High  
**Effort:** Medium (4-6 hours)  
**Merged:** `main`

### What was done

- **Backend:** `Transmittal` model with `belongs_to :pay_period`; `transmittals` table stores preparer name, notes, report list, check numbers, and timestamps.
- **Controller:** `save_transmittal_state!` auto-saves transmittal options when generating PDF; `transmittal_preview` returns saved state; dedicated endpoint for retrieval.
- **Frontend:** `TransmittalEditorModal` pre-populates fields from saved state on reopen; "Last generated" indicator displayed.

---

## Feature 3: Employee Bulk Import

**Status:** ✅ DONE  
**Priority:** Critical (MoSa onboarding — 50+ employees)  
**Effort:** Medium-Large (6-10 hours)  
**Merged:** `main`

### What was done

- **Backend:** `EmployeeBulkImportsController` with `preview` and `apply` endpoints; `ImportService` handles CSV/Excel parsing, validation, and duplicate detection.
- **Frontend:** `EmployeeBulkImportModal` with file upload, preview table with row-by-row validation, confirm & import flow.
- Employee list page has "Bulk Import" button.

---

## Feature 4: Payroll Reminders

**Status:** ✅ DONE  
**Priority:** Medium  
**Effort:** Medium (6-8 hours)  
**Merged:** `main`

### What was done

- **Backend:** `PayrollReminderConfig` model per company; `PayrollReminderJob` runs daily via Solid Queue; `PayrollReminderMailer` sends via Resend.
- **Controller:** Full CRUD for reminder config + test send endpoint.
- **Frontend:** Dedicated `PayrollReminders` page with enable/disable toggle, recipient management, pay schedule configuration, send test, and reminder history log.

---

## Feature 5: Reports UI Completion

**Status:** ✅ DONE  
**Priority:** High  
**Effort:** Medium (4-6 hours)  
**Branch:** `feature/reports-ui-form500-docs-update`

### What was done

- **Employee Pay History** tile — Select an employee, view last N pay periods with gross/net/hours, plus YTD summary. Uses existing `reportsApi.employeePayHistory`.
- **YTD Summary** tile — Select a year, view all employees with gross/withholding/SS/Medicare/retirement/net. Uses existing `reportsApi.ytdSummary`.
- **Employer Tax Liability** tile — Quarterly employer-side tax totals (employer SS + employer Medicare). Derived from existing `reportsApi.taxSummary`.
- **Form 941-GU** tile — Quarterly filing data display with all 941-GU line items, monthly liability breakdown. Uses new `reportsApi.form941Gu`.
- All four tiles wired with Generate Report, error handling, and proper data tables.
- Removed "Coming Soon" placeholder for 941-GU.

---

## Execution Summary

| Order | Feature | Status |
|-------|---------|--------|
| 1st | Form 500 Link | ✅ Done |
| 2nd | Save Transmittal State | ✅ Done |
| 3rd | Employee Bulk Import | ✅ Done |
| 4th | Payroll Reminders | ✅ Done |
| 5th | Reports UI Completion | ✅ Done |

---

## Remaining Work (Future Roadmap)

### High Priority
- **Off-cycle / bonus payroll runs** — `pay_type` enum on PayPeriod
- **Pay stub email delivery** — ActionMailer/Resend integration with PayStubGenerator
- **W-2GU EFW2 electronic filing** — Guam DRT accepts EFW2 format

### Medium Priority
- **General ledger export** — GL account mapping + CSV/PDF export
- **Audit log CSV export** — Add to audit_logs_controller
- **ACH / NACHA direct deposit file** — Bank routing/account on employee

### Lower Priority
- Employee self-service portal
- MFA enforcement
- Garnishment deduction types
- Role/permission matrix UI

---

## Notes

- MoSa is actively using the application on prod with 50+ employees imported via bulk import.
- All core QB replacement features are now implemented: payroll calculation, tax compliance (Pub 15-T annualized, SS wage base cap, Additional Medicare), check printing, W-2GU, 1099-NEC, 941-GU, transmittal, and timecard OCR.
- Form 500 is Guam-specific (DRT Depository Receipt for Income Tax Withheld). If we onboard non-Guam clients, this should be configurable per jurisdiction.
