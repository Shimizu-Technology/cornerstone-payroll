# Feature Roadmap — March 2026

Comprehensive tracker for all planned improvements, bug fixes, and new features.
Audited against codebase on 2026-03-30. Updated 2026-03-30.

---

## Tier 1 — Critical for Daily Operations (ALL COMPLETE)

### 1. Roll Back Approved Pay Period
- **Status:** ✅ DONE (PR #28)
- **What was done:** Added `unapprove` action on `PayPeriodsController` that moves `approved → calculated`, clears `approved_by_id`. UI button on PayPeriodDetail.
- **Files:** `api/app/controllers/api/v1/admin/pay_periods_controller.rb`, `api/config/routes.rb`, `web/src/pages/PayPeriodDetail.tsx`, `web/src/services/api.ts`

### 2. Skip $0 Net Pay Checks When Printing
- **Status:** ✅ DONE (PR #28)
- **What was done:** $0 net pay items are excluded from check number assignment at commit time (`net_pay.to_d > 0` filter) and from batch PDF generation (`printable_items` filtering). Uses in-memory filtering with bulk `insert_all!` for audit events.
- **Files:** `api/app/controllers/api/v1/admin/pay_periods_controller.rb`, `api/app/controllers/api/v1/admin/checks_controller.rb`

### 3. User Management Scoping Bug
- **Status:** ✅ DONE (PR #28)
- **What was done:** Admin users now see all users globally (not company-scoped). `set_user` finds any user by ID. New user creation assigns to admin's home company. Global safety checks for last-admin protections.
- **Files:** `api/app/controllers/api/v1/admin/users_controller.rb`

### 4. Invite Link Goes to Clerk Instead of App
- **Status:** ✅ DONE (PR #28)
- **What was done:** `UserInviteEmailService` now always links to `#{frontend_url}/login` instead of the Clerk-hosted invitation URL.
- **Files:** `api/app/services/user_invite_email_service.rb`

### 5. Check Memo Configurability
- **Status:** ✅ DONE (PR #28)
- **What was done:** Added `check_memo_template` column to companies table. `CheckGenerator#resolve_memo_text` supports placeholders: `{employee_name}`, `{employee_first_name}`, `{employee_last_name}`, `{period_start}`, `{period_end}`, `{pay_date}`, `{check_number}`, `{company_name}`. UI field in Check Settings page.
- **Files:** `api/app/services/check_generator.rb`, `api/db/migrate/20260330081250_add_check_memo_template_to_companies.rb`, `web/src/pages/CheckSettings.tsx`

---

## Tier 2 — Important for Accuracy & Compliance (ALL COMPLETE)

### 6. W-4 Transparency on Check Stubs & Reports
- **Status:** ✅ DONE (PR #28)
- **What was done:** W-4 indicators (Step2, 4a, 4b, Override) integrated into the Federal Income Tax line within the TAXES table on check stubs. W-4 transparency badges (FIT Override, Step 2, additional withholding) shown on PayPeriodDetail next to employee names.
- **Files:** `api/app/services/check_generator.rb`, `web/src/pages/PayPeriodDetail.tsx`

### 7. 1099 Contractor Separation in Reports
- **Status:** ✅ DONE (PR #28)
- **What was done:** Payroll register separates W-2 employees from 1099 contractors with distinct summary sections (`employees` vs `contractors` arrays, separate totals). Payroll summary by employee excludes contractors entirely (W-2 tax report).
- **Files:** `api/app/controllers/api/v1/admin/reports_controller.rb`, `api/app/services/payroll_summary_by_employee_pdf_generator.rb`

### 8. Payroll by Employee Report — Employee Names in Breakdown
- **Status:** ✅ DONE (PR #28)
- **What was done:** Added `render_employee_name_header` method that draws a blue header row with employee names (including "(1099)" for contractors) as column headers.
- **Files:** `api/app/services/payroll_summary_by_employee_pdf_generator.rb`

### 9. Accountant Permission Scoping
- **Status:** ✅ DONE (PR #28)
- **What was done:** `enforce_company_access!` added as before_action in BaseController. `accessible_company_ids` for accountants/managers returns only explicitly assigned companies. `resolve_company_id` gracefully falls back to first accessible company when home company is inaccessible. Company switcher shows all accessible companies (including inactive). `companies#index` skips `enforce_company_access!` (discovery endpoint).
- **Files:** `api/app/controllers/api/v1/admin/base_controller.rb`, `api/app/controllers/application_controller.rb`, `api/app/models/user.rb`, `api/app/controllers/api/v1/admin/companies_controller.rb`, `web/src/contexts/CompanyContext.tsx`, `web/src/components/layout/CompanySwitcher.tsx`

### 10. 1099 Separation in Hour Input List
- **Status:** ✅ DONE (PR #28)
- **What was done:** Hours input table groups employees by type (Salary → Hourly → 1099 Contractors) with descriptive section headers. Alphabetical sorting within each group.
- **Files:** `web/src/pages/PayPeriodDetail.tsx`

---

## Tier 3 — Next Up (ALL COMPLETE)

### 11. Transmittal Editing Before Printing
- **Status:** ✅ DONE
- **What was done:** Added `TransmittalEditorModal` in `ReportsDownloadPanel` that opens before generating Transmittal Log or Full Print Package PDFs. Users can edit preparer name, add/remove/edit notes, and customize the reports list. Backend `transmittal_options` helper extracts `preparer_name`, `notes[]`, and `report_list[]` from params. Routes now accept both GET and POST for transmittal/full-package endpoints. Frontend API uses `postBlob` to send complex JSON bodies.
- **Files:** `web/src/components/reports/ReportsDownloadPanel.tsx`, `web/src/services/api.ts`, `api/app/controllers/api/v1/admin/reports_controller.rb`, `api/config/routes.rb`

### 12. Auto-Create FIT Check with Payroll
- **Status:** ✅ DONE
- **What was done:** Added `auto_create_fit_check` boolean column to companies (default false). When enabled, committing payroll auto-creates a `NonEmployeeCheck` of type `tax_deposit` for total FIT (W-2 employees only), payable to "EFTPS - Federal Income Tax". Toggle added to Check Settings page under "Payroll Automation" section.
- **Files:** `api/db/migrate/20260330233203_add_auto_create_fit_check_to_companies.rb`, `api/app/controllers/api/v1/admin/pay_periods_controller.rb`, `api/app/controllers/api/v1/admin/checks_controller.rb`, `web/src/pages/CheckSettings.tsx`, `web/src/types/index.ts`

### 13. Timecard OCR Import
- **Status:** ✅ DONE
- **What was done:** Added CSV import flow for Timecard OCR exports. Backend `TimecardImportsController` parses CSV, fuzzy-matches employee names using trigram similarity, and returns a preview with match scores. Frontend `TimecardImportModal` provides a 3-step flow: upload CSV → review/remap employee mappings → apply. Hours are imported as `import_source: "timecard_ocr"`. Accessible from PayPeriodDetail via "Import (Timecard OCR)" button on draft pay periods.
- **Files:** `api/app/controllers/api/v1/admin/timecard_imports_controller.rb`, `api/config/routes.rb`, `web/src/components/payroll/TimecardImportModal.tsx`, `web/src/pages/PayPeriodDetail.tsx`, `web/src/services/api.ts`

---

## Tier 3 — Deferred

### 14. WebSockets for Real-Time Updates
- **Status:** NOT STARTED (infrastructure exists)
- **Current state:** `solid_cable` gem is in Gemfile, `cable.yml` exists, but zero channels are implemented.
- **Problem:** When multiple users are working simultaneously, changes don't appear until page refresh. Risk of race conditions (e.g., two people editing the same pay period).
- **Solution:** Implement ActionCable channels for: pay period status changes, payroll item updates, lock/unlock mechanism for pay periods being edited.
- **Files:** New `api/app/channels/`, `web/` WebSocket client integration
- **Effort:** Large

### 15. Production Performance (Infrastructure)
- **Status:** IN PROGRESS
- **Current state:** Code-level optimizations deployed (N+1 fixes, batch operations, PR #27). Database is on Neon with auto-suspend causing cold starts.
- **Solution:** Configure Neon: disable scale-to-zero, set minimum compute to 1 CU. Consider Render region proximity to Neon region. Monitor after changes.
- **Files:** Neon dashboard, Render dashboard
- **Effort:** Small (config changes)

---

## Already Done (No Work Needed)

| Feature | Status | Notes |
|---------|--------|-------|
| Employee count on employees page | DONE | Shows "Showing X of Y employees" via `meta.total_count` |
| Manual FIT override | DONE | `withholding_tax_override` field, UI, calculator, check stub labeling |
| Non-employee/random checks | DONE | Full CRUD, PDF generation, transmittal integration |
| Reports tab/page with pay period selection | DONE | Sidebar link, `Reports.tsx` with pay period selector |
| Check number tracking/management | DONE | Auto-increment, admin settings, `next_check_number` |
| 1099 separation in UI (pay period detail) | DONE | Green-tinted rows, separate contractor sections |
| Check Settings in sidebar | DONE | "Settings" section with Check Settings link |
| Check preview modal (z-index/size) | DONE | React Portal, 95vw/92vh, z-[9999] |

---

## Notes

- Tax Sync "Failed" badge is a known non-critical issue (documented in `PRODUCTION_FOLLOWUP_ROADMAP_2026-03-29.md`). Will resolve when CST_INGEST_URL is configured.
- Check printing layout was extensively tuned in a previous session and is working correctly with browser print offsets.
- Correction/void workflow is fully implemented for committed pay periods.
- Greptile reviews: PR #28 received 5/5 confidence score on all three reviews.
