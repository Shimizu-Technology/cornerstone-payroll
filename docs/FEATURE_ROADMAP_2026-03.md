# Feature Roadmap — March 2026

Comprehensive tracker for all planned improvements, bug fixes, and new features.
Audited against codebase on 2026-03-30.

---

## Tier 1 — Critical for Daily Operations

### 1. Roll Back Approved Pay Period
- **Status:** NOT IMPLEMENTED
- **Problem:** Once a pay period is approved, there's no way to undo it without voiding (which requires committing first). If you approve by mistake, you're stuck.
- **Solution:** Add an `unapprove` action on `PayPeriodsController` that moves `approved → calculated`. Simple status change, no YTD impact since nothing has been committed.
- **Files:** `api/app/controllers/api/v1/admin/pay_periods_controller.rb`, `web/src/pages/PayPeriodDetail.tsx`
- **Effort:** Small

### 2. Skip $0 Net Pay Checks When Printing
- **Status:** NOT IMPLEMENTED
- **Problem:** `batch_pdf` includes all payroll items with check numbers, even if net pay is $0. Wastes paper and causes confusion.
- **Solution:** Filter out items where `net_pay <= 0` in `checks_controller#batch_pdf` (or don't assign check numbers to $0 items in the first place).
- **Files:** `api/app/controllers/api/v1/admin/checks_controller.rb`, `api/app/models/company.rb` (`assign_check_numbers!`)
- **Effort:** Small

### 3. User Management Scoping Bug
- **Status:** BUG — NEEDS FIX
- **Problem:** `UsersController` always scopes to `current_user.company_id` (the admin's home company) via `staff_company_id`, not the currently selected company (`X-Company-Id` header / `resolve_company_id`). Creating a user while viewing Company B assigns them to Company A (admin's home). Users don't appear under the company you're looking at.
- **Solution:** Change `staff_company_id` to use `current_company_id` (which respects the `X-Company-Id` header) for super_admin users, or always scope user CRUD to the selected company context. Need to be careful about security — only super_admins should be able to manage users across companies.
- **Files:** `api/app/controllers/api/v1/admin/users_controller.rb`, `api/app/controllers/application_controller.rb`
- **Effort:** Medium (security implications)

### 4. Invite Link Goes to Clerk Instead of App
- **Status:** NEEDS INVESTIGATION
- **Problem:** When users click the invite link, they end up on Clerk's hosted page instead of the app's login page.
- **Solution:** Verify `FRONTEND_URL` is set correctly on Render. Also check Clerk dashboard → Paths → "After sign-up URL" and "After sign-in URL" to ensure they redirect to the app. The code in `build_redirect_url` looks correct (`#{frontend}/login`), so this is likely a Clerk dashboard or env var configuration issue.
- **Files:** `api/app/controllers/api/v1/admin/users_controller.rb` (`build_redirect_url`), Clerk dashboard settings, Render env vars
- **Effort:** Small (config check)

### 5. Check Memo Configurability
- **Status:** NOT IMPLEMENTED
- **Problem:** Check memo is hardcoded as `"Payroll {start} - {end}"`. For some clients, you want employee name/address or custom text (like the stateside address use case from QuickBooks).
- **Solution:** Add a `check_memo_template` field to company check_settings. Support placeholders like `{employee_name}`, `{employee_address}`, `{period_start}`, `{period_end}`, `{pay_date}`. Default to current format for backward compatibility.
- **Files:** `api/app/services/check_generator.rb`, `api/app/controllers/api/v1/admin/checks_controller.rb` (check_settings), `web/src/components/checks/` (settings UI)
- **Effort:** Medium

---

## Tier 2 — Important for Accuracy & Compliance

### 6. W-4 Transparency on Check Stubs & Reports
- **Status:** PARTIALLY DONE
- **Current state:** Check stubs show FIT override asterisk and "Addtl W/H (W-4 4c)" when > 0. Step 2 checkbox, Step 4a (other income), and Step 4b (deductions) are NOT shown on stubs or reports.
- **Solution:** Add a W-4 summary section to check stubs showing all active W-4 modifiers. Include in payroll register and summary reports. Makes it clear why one employee's FIT differs from another's.
- **Files:** `api/app/services/check_generator.rb`, `api/app/services/pay_stub_generator.rb`, `api/app/services/payroll_register_pdf_generator.rb`, report generators
- **Effort:** Medium

### 7. 1099 Contractor Separation in Reports
- **Status:** PARTIALLY DONE
- **Current state:** Payroll register excludes contractors in at least one code path. UI separates them visually. But other reports may still mix contractors with W-2 employees.
- **Solution:** Audit every report generator to ensure contractors are either excluded from tax-related reports or shown in a clearly separate section. 1099-NEC generation already exists.
- **Files:** All files in `api/app/services/*_generator.rb`, `api/app/controllers/api/v1/admin/reports_controller.rb`
- **Effort:** Medium

### 8. Payroll by Employee Report — Employee Names in Breakdown
- **Status:** PARTIALLY DONE
- **Problem:** `PayrollSummaryByEmployeePdfGenerator` creates columns per employee but doesn't render clear employee name headers per column.
- **Solution:** Add employee name header row at the top of each column or group.
- **Files:** `api/app/services/payroll_summary_by_employee_pdf_generator.rb`
- **Effort:** Small

### 9. Accountant Permission Scoping
- **Status:** NOT IMPLEMENTED
- **Problem:** Accountants can access all companies through the admin API. `company_assignments` data exists but isn't enforced as a filter for non-super-admin users.
- **Solution:** Add a `before_action` filter in `BaseController` that, for accountant-role users, restricts `current_company_id` to only companies they're assigned to. Admin and super_admin users would be unaffected.
- **Files:** `api/app/controllers/api/v1/admin/base_controller.rb`, `api/app/controllers/application_controller.rb`
- **Effort:** Medium

### 10. 1099 Separation in Hour Input List
- **Status:** NOT IMPLEMENTED (separate from #7)
- **Problem:** When inputting hours on the pay period page, contractors and W-2 employees are mixed together (though contractors have a green tint).
- **Solution:** Group the hours input list by employment type — all W-2 hourly employees first, then W-2 salary, then 1099 contractors. Add section headers.
- **Files:** `web/src/pages/PayPeriodDetail.tsx`
- **Effort:** Small

---

## Tier 3 — Nice to Have / Larger Effort

### 11. Transmittal Editing Before Printing
- **Status:** PARTIALLY DONE
- **Current state:** Can pass `preparer_name` and `notes` at generation time. No persistent draft or preview/edit UI.
- **Solution:** Add a modal or page where you can preview the transmittal, edit preparer name, add/remove notes lines, then generate the PDF.
- **Files:** `web/src/components/checks/TransmittalPanel.tsx` (or new), `api/app/controllers/api/v1/admin/checks_controller.rb`
- **Effort:** Medium

### 12. Auto-Create FIT Check with Payroll
- **Status:** NOT IMPLEMENTED
- **Problem:** After running payroll, you manually create a non-employee check for the total FIT amount. This should be automated.
- **Solution:** When payroll is committed, auto-generate a non-employee check for "Federal Income Tax" with the sum of all FIT from that pay period. Make it optional/configurable per company.
- **Files:** `api/app/controllers/api/v1/admin/pay_periods_controller.rb` (commit action), `api/app/models/non_employee_check.rb`
- **Effort:** Medium

### 13. WebSockets for Real-Time Updates
- **Status:** NOT IMPLEMENTED (infrastructure exists)
- **Current state:** `solid_cable` gem is in Gemfile, `cable.yml` exists, but zero channels are implemented.
- **Problem:** When multiple users are working simultaneously, changes don't appear until page refresh. Risk of race conditions (e.g., two people editing the same pay period).
- **Solution:** Implement ActionCable channels for: pay period status changes, payroll item updates, lock/unlock mechanism for pay periods being edited.
- **Files:** New `api/app/channels/`, `web/` WebSocket client integration
- **Effort:** Large

### 14. Timecard OCR Integration
- **Status:** SEPARATE PROJECT
- **Location:** `~/Desktop/ShimizuTechnology/timecard-ocr`
- **Description:** Full Rails + React app that uses OCR to extract hours from Pyramid-style paper timecards. Currently standalone.
- **Solution options:**
  1. **API bridge:** Timecard OCR exports CSV/JSON, payroll app imports it (like the existing MoSa import)
  2. **Embedded module:** Mount as a Rails engine within the payroll app
  3. **Standalone with link:** Keep separate, add a "Import from Timecard OCR" button
- **Effort:** Large (option 1 is smallest)

### 15. Production Performance (Infrastructure)
- **Status:** IN PROGRESS
- **Current state:** Code-level optimizations deployed (N+1 fixes, batch operations). Database is on Neon with auto-suspend causing cold starts.
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

---

## Notes

- Tax Sync "Failed" badge is a known non-critical issue (documented in `PRODUCTION_FOLLOWUP_ROADMAP_2026-03-29.md`). Will resolve when CST_INGEST_URL is configured.
- Check printing layout was extensively tuned in a previous session and is working correctly with browser print offsets.
- Correction/void workflow is fully implemented for committed pay periods.
