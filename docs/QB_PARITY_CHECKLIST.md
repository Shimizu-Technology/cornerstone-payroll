# QuickBooks Parity Checklist — Cornerstone Payroll

**Purpose:** Track feature parity vs QuickBooks (Cornerstone's current system) to drive roadmap prioritization toward full QB replacement.  
**Context:** Cornerstone uses QB primarily for check printing, tax calculations, and payroll reports. The goal is to fully replace QB — including the check-printing workflow — so Cornerstone can process payroll for internal staff and client companies without the QB overhead or Guam address workarounds.

**Status key:**
- ✅ **Done** — Implemented and in production/staging
- 🟡 **Partial** — Core exists but gaps remain (see "Next Actions")
- ❌ **Missing** — Not yet implemented

**Last updated:** 2026-03-09

---

## 1. Payroll Run

| Feature | QB Has It? | Our Status | Notes | Next Actions |
|---------|-----------|------------|-------|--------------|
| Enter hours per employee per period | ✅ | ✅ **Done** | `PayrollItem` with hours/OT hours; hourly + salary calculators | — |
| Calculate gross pay (hourly + OT) | ✅ | ✅ **Done** | `HourlyPayrollCalculator`, 1.5× OT rate | — |
| Calculate gross pay (salary) | ✅ | ✅ **Done** | `SalaryPayrollCalculator` | — |
| Biweekly pay period grouping | ✅ | ✅ **Done** | `PayPeriod` model with date range + status | — |
| Multi-employee bulk entry | ✅ | ✅ **Done** | `PayPeriodDetail` page with per-employee rows | — |
| Import from Revel POS PDF | ❌ (manual) | ✅ **Done** | `RevelPdfParser` — fixed-column + fallback flexible parser | — |
| Import loan/tip deductions from Excel | ❌ (manual) | ✅ **Done** | `LoanTipExcelParser` — multi-sheet support | — |
| Fuzzy employee name matching on import | ❌ | ✅ **Done** | `NameMatcher` — exact → normalized → fuzzy → alias | — |
| Employee backfill (unmatched names) | ❌ | ✅ **Done** | `mosa_backfill_employees.rb` — skeleton records | — |
| Pay period status workflow (draft → approved → committed) | ✅ | 🟡 **Partial** | `draft → calculated → approved → committed` exists; UI approval step present | Add manager sign-off email notification on approval |
| Paycheck number assignment | ✅ | 🟡 **Partial** | `check_number` field exists on `PayrollItem` | Auto-sequence check numbers on commit (currently manual entry) |
| Voiding / adjusting a committed payroll | ✅ | ❌ **Missing** | No void/adjustment flow | Add `voided` status + adjustment payroll item type; scope to admin only |
| Off-cycle / bonus payroll run | ✅ | ❌ **Missing** | Only biweekly supported | Add `pay_type` enum on `PayPeriod` (regular / bonus / adjustment) |
| Tips as pay item | ✅ | ✅ **Done** | Tips tracked per employee per period via Excel import | — |
| Loan deductions | ✅ | ✅ **Done** | Loan deductions from Excel; stored on `PayrollItem` | — |
| Retirement deductions | ✅ | ✅ **Done** | `retirement_payment` on `PayrollItem`, configurable per employee | — |
| Custom deduction types | ✅ | ✅ **Done** | `DeductionType` model + `EmployeeDeduction` | — |

---

## 2. Employee & Year Tracking

| Feature | QB Has It? | Our Status | Notes | Next Actions |
|---------|-----------|------------|-------|--------------|
| Employee master record (name, address, filing status) | ✅ | ✅ **Done** | `Employee` model — name, SSN (encrypted?), filing_status, allowances | Confirm SSN field is encrypted at rest |
| Hourly vs salary employment type | ✅ | ✅ **Done** | `employment_type` enum on `Employee` | — |
| Pay rate storage | ✅ | ✅ **Done** | `pay_rate decimal(10,4)` — precision migration done in this PR | — |
| W-4GU allowances | ✅ | 🟡 **Partial** | `allowances` field stored; not yet used in withholding calculation | Wire allowances into `GuamTaxCalculator` — reduces taxable wages by allowance × annual amount / 26 |
| YTD gross per employee | ✅ | ✅ **Done** | `EmployeeYtdTotal` — gross, withholding, SS, Medicare, retirement, net | — |
| YTD totals by company | ✅ | ✅ **Done** | `CompanyYtdTotal` | — |
| YTD totals by department | ✅ | ✅ **Done** | `DepartmentYtdTotal` | — |
| SS wage base cap ($176,100 for 2025) | ✅ | ❌ **Missing** | Calculator doesn't stop SS withholding at $176,100 YTD | Add `ytd_gross` check in `GuamTaxCalculator` before computing SS; use `EmployeeYtdTotal` |
| Additional Medicare Tax (0.9% over $200K) | ✅ | ❌ **Missing** | Not implemented | Add after SS wage base cap fix; low priority for Guam restaurant staff |
| Employee status (active / inactive / terminated) | ✅ | ✅ **Done** | `status` field on `Employee` | — |
| Hire date / termination date | ✅ | 🟡 **Partial** | `hired_on` exists; no termination date field | Add `terminated_on` to employees; use to auto-inactivate |
| Department assignment | ✅ | ✅ **Done** | `Department` → `Employee` belongs_to | — |
| Multi-company (client payroll) | ✅ | ✅ **Done** | `company_id` scoping throughout; `current_company_id` in auth | — |

---

## 3. Reports & Exports

| Feature | QB Has It? | Our Status | Notes | Next Actions |
|---------|-----------|------------|-------|--------------|
| Payroll register (per period, all employees) | ✅ | ✅ **Done** | `ReportsController#payroll_register` — returns JSON | Add PDF export via Prawn (same pattern as `PayStubGenerator`) |
| Employee pay history | ✅ | ✅ **Done** | `ReportsController#employee_pay_history` — last N committed periods | — |
| YTD summary report (all employees) | ✅ | ✅ **Done** | `ReportsController#ytd_summary` — per employee + company totals | — |
| Tax withholding summary (quarterly) | ✅ | ✅ **Done** | `ReportsController#tax_summary` — year + optional quarter param | — |
| Dashboard / stats | ✅ | ✅ **Done** | `ReportsController#dashboard` — headcount, YTD, recent payrolls | — |
| Payroll register PDF export | ✅ | ❌ **Missing** | JSON only; no PDF version of the register | Add `PayrollRegisterGenerator` (Prawn) — 1-2 days |
| YTD summary PDF/CSV export | ✅ | ❌ **Missing** | JSON only | Add CSV export (fast) + PDF (use Prawn table) |
| Tax summary PDF export | ✅ | ❌ **Missing** | JSON only | Needed for client delivery; add alongside payroll register PDF |
| General ledger export | ✅ | ❌ **Missing** | Not planned yet | Scope after core reports; needs GL account mapping config |
| QuickBooks IIF/CSV export | ✅ | ❌ **Missing** | Not planned | Low priority once fully replacing QB; medium priority if clients still use QB |
| Bank reconciliation report | ✅ | ❌ **Missing** | Not planned | Add after check printing is live |
| Garnishment / special deduction reporting | ✅ | ❌ **Missing** | No garnishment type or report | Add `GarnishmentDeduction` type to `DeductionType`; scope to court orders |

---

## 4. Tax & Compliance Outputs

| Feature | QB Has It? | Our Status | Notes | Next Actions |
|---------|-----------|------------|-------|--------------|
| DRT (Guam territorial income tax) withholding | ✅ | ✅ **Done** | `GuamTaxCalculator` — tax bracket tables, filing status | Audit annualization method (see caveats below) |
| Social Security withholding (employee 6.2%) | ✅ | ✅ **Done** | `GuamTaxCalculator` | Add SS wage base cap (see Employee tracking) |
| Medicare withholding (employee 1.45%) | ✅ | ✅ **Done** | `GuamTaxCalculator` | — |
| Employer SS match (6.2%) | ✅ | ✅ **Done** | `employer_social_security_tax` on `PayrollItem` | — |
| Employer Medicare match (1.45%) | ✅ | ✅ **Done** | `employer_medicare_tax` on `PayrollItem` | — |
| Annualized withholding method (IRS Pub 15-T) | ✅ | ❌ **Missing** | Current: tax brackets applied to per-period gross, not annualized | Implement annualize → apply bracket → de-annualize in `GuamTaxCalculator`; prevents systematic under-withholding |
| Tax table as database-driven data | ✅ | 🟡 **Partial** | `TaxBracket`, `TaxTable`, `AnnualTaxConfig` models exist; `FilingStatusConfig` | Validate brackets match current DRT tables; add admin UI to update brackets without code deploy |
| 941-GU quarterly filing report | ✅ | ❌ **Missing** | `tax_summary` endpoint has the right numbers; no 941-GU formatted output | Format `tax_summary` output as 941-GU-compatible PDF; verify line mapping against GRT/DRT forms |
| W-2GU annual generation | ✅ | ❌ **Missing** | Not implemented | High priority for Jan year-end; needs employee SSN, YTD totals, employer EIN. Use Prawn |
| W-2GU XML/EFW2 file (electronic filing) | ✅ | ❌ **Missing** | Not implemented | Follow after W-2GU PDF; Guam DRT accepts EFW2 format |
| 1099-NEC (contractor payments) | ✅ | ❌ **Missing** | No contractor payment type | Add `contractor` employment type; 1099-NEC generation in Q4 |
| ACH / direct deposit file generation (NACHA) | ✅ | ❌ **Missing** | Not implemented | Phase 2; requires bank routing/account on employee; NACHA format output |
| Check printing (MICR / pre-printed stock) | ✅ | 🟡 **Partial** | `PayStubGenerator` uses Prawn; check-printing code exists but is screen-only per PRD | Verify `check_writer` gem integration; test against Bank of Guam pre-printed stock; add MICR encoding |

---

## 5. Audit Trail & History

| Feature | QB Has It? | Our Status | Notes | Next Actions |
|---------|-----------|------------|-------|--------------|
| Payroll item creation/edit history | ✅ | ✅ **Done** | `AuditLog` model + `audit_logs_controller.rb` | — |
| Tax config change history | ✅ | ✅ **Done** | `TaxConfigAuditLog` — separate model for tax table changes | — |
| Import session ledger | ❌ (no import in QB) | ✅ **Done** | `PayrollImportRecord` — status, filenames, matched/unmatched data | — |
| Audit log filtering (action, date, user) | ✅ | 🟡 **Partial** | Backend supports filtering; advanced UI filters pending per `FUTURE_IMPROVEMENTS.md` | Add action-group and entity-type filters to UI |
| Audit log CSV export | ✅ | ❌ **Missing** | Listed in `FUTURE_IMPROVEMENTS.md` | Add CSV export to `audit_logs_controller.rb` — 0.5 day |
| Audit log retention policies | ✅ | ❌ **Missing** | Listed in `FUTURE_IMPROVEMENTS.md` | Define retention window (e.g., 7 years for payroll per IRS); add archive/purge rake task |
| Who-ran-payroll tracking | ✅ | ✅ **Done** | `current_user` on audit logs; import records linked to user session | — |
| Rollback a pay period's import | limited | ✅ **Done** | `PayPeriod#payroll_items.destroy_all` — safe, documented in RUNBOOK | Add UI button for admin rollback with confirmation modal |

---

## 6. Operational Controls

| Feature | QB Has It? | Our Status | Notes | Next Actions |
|---------|-----------|------------|-------|--------------|
| Role-based access (admin vs manager) | ✅ | ✅ **Done** | `User` roles; `BaseController` enforces access | — |
| Role/permission matrix UI | ✅ | ❌ **Missing** | Listed in `FUTURE_IMPROVEMENTS.md` | Add per-role toggle grid; low priority for now |
| User invitation flow | ✅ | ✅ **Done** | `UserInvitation` model + invite controller; invite email sent via Clerk | — |
| MFA enforcement | ✅ | ❌ **Missing** | Listed in `FUTURE_IMPROVEMENTS.md` | Clerk supports MFA; add policy config per company |
| Multi-company isolation | ✅ | ✅ **Done** | `company_id` scoping; `current_company_id` in all admin routes | — |
| Pay period locking (prevent edits after commit) | ✅ | ✅ **Done** | `can_edit?` check on `PayPeriod`; `committed` status blocks import | — |
| Tax config admin UI | ✅ | 🟡 **Partial** | `tax_configs_controller.rb` exists; DRT brackets configurable | Add validation that bracket totals are internally consistent; add history diff view |
| Payroll email notifications | ✅ | ❌ **Missing** | No email on pay period approval, commit, or error | Add ActionMailer: "Your payroll for [period] has been committed" to company admin |
| Employee self-service portal | ✅ | ❌ **Missing** | No employee-facing UI | Phase 3 — employees view own pay stubs, update W-4GU info |
| Pay stub delivery (email / portal) | ✅ | ❌ **Missing** | `PayStubGenerator` generates PDF; no delivery mechanism | Add `pay_stub_controller` send action: generate Prawn PDF → email via ActionMailer or store in R2 |
| API health monitoring / alerting | limited | ❌ **Missing** | No monitoring configured | Add `/health` endpoint; set up Render health check; Sentry or Honeybadger for errors |

---

## Priority Summary

### 🔴 High — Blocks full QB replacement

1. **Annualized withholding** — Prevents systematic under-withholding for mid-to-high earners
2. **SS wage base cap ($176,100)** — Legally required; currently over-withholds for high earners
3. **W-2GU generation** — Required annually in January
4. **Payroll register PDF export** — Cornerstone hands these to clients; JSON isn't usable
5. **Check printing (final validation)** — Prawn code exists but needs MICR + real stock test

### 🟠 Medium — Needed for Cornerstone scale-up

6. **941-GU quarterly filing report** — Required quarterly; currently manual
7. **YTD summary CSV/PDF export** — Client-facing deliverable
8. **Tax table admin UI** — Allows DRT rate changes without code deploy
9. **Voiding / adjusting committed payroll** — Inevitable corrections will happen
10. **Pay stub email delivery** — Replaces printing + mailing for most employees

### 🟡 Lower — QoL / compliance completeness

11. Audit log CSV export + retention policy
12. ACH / NACHA direct deposit file
13. W-2GU EFW2 electronic filing
14. MFA enforcement per company
15. Employee self-service portal (Phase 3)
16. Garnishment deduction type
17. Role/permission matrix UI

---

*Document owner: Leon Shimizu / Shimizu Technology*  
*Based on: PRD.md, BUILD_PLAN.md, FUTURE_IMPROVEMENTS.md, and actual code review of `api/app/`*  
*Last updated: 2026-03-09*
