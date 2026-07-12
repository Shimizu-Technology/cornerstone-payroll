# QuickBooks Parity Checklist — Cornerstone Payroll

> **Planning note (2026-07-11):** This checklist is a useful feature inventory, but its older "Done" labels do not mean a return is filing-ready, filed, accepted, or correctable. Current priorities and release gates are defined in the [Payroll, QuickBooks, and Compliance Master Plan](PAYROLL_QUICKBOOKS_COMPLIANCE_MASTER_PLAN_2026-07-11.md). This checklist covers Cornerstone's payroll use of QuickBooks; it does not claim complete QuickBooks accounting parity.

**Purpose:** Track feature parity vs QuickBooks (Cornerstone's current system) to drive roadmap prioritization toward full QB replacement.  
**Context:** Cornerstone uses QB primarily for check printing, tax calculations, and payroll reports. The goal is to fully replace QB — including the check-printing workflow — so Cornerstone can process payroll for internal staff and client companies without the QB overhead or Guam address workarounds.

**Status key:**
- ✅ **Done** — Implemented and in production/staging
- 🟡 **Partial** — Core exists but gaps remain (see "Next Actions")
- ❌ **Missing** — Not yet implemented

**Last updated:** 2026-05-24

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
| Pay period status workflow (draft → approved → committed) | ✅ | ✅ **Done** | `draft → calculated → approved → committed` with full UI workflow | — |
| Paycheck number assignment | ✅ | ✅ **Done** | Auto-sequencing on commit; manual override available | — |
| Voiding / adjusting a committed payroll | ✅ | ✅ **Done** | `correction_status` (voided/correction) on `PayPeriod`; void + correction run workflow with audit trail | — |
| Off-cycle / bonus payroll run | ✅ | ❌ **Missing** | Only regular pay periods supported | Add `pay_type` enum on `PayPeriod` (regular / bonus / adjustment) |
| Tips as pay item | ✅ | ✅ **Done** | Tips tracked per employee per period via Excel import | — |
| Loan deductions | ✅ | ✅ **Done** | Loan deductions from Excel; stored on `PayrollItem` | — |
| Retirement deductions | ✅ | ✅ **Done** | `retirement_payment` on `PayrollItem`, configurable per employee | — |
| Custom deduction types | ✅ | ✅ **Done** | `DeductionType` model + `EmployeeDeduction` | — |
| Timecard OCR (phone photo → hours) | ❌ | ✅ **Done** | Upload timecard images, OCR extraction, review/edit UI with zoom, employee matching | — |

---

## 2. Employee & Year Tracking

| Feature | QB Has It? | Our Status | Notes | Next Actions |
|---------|-----------|------------|-------|--------------|
| Employee master record (name, address, filing status) | ✅ | ✅ **Done** | `Employee` model with encrypted SSN, filing status, W-4 fields | — |
| Hourly vs salary employment type | ✅ | ✅ **Done** | `employment_type` enum on `Employee` | — |
| Pay rate storage | ✅ | ✅ **Done** | `pay_rate decimal(10,4)` | — |
| W-4GU / W-4 fields (2020+ format) | ✅ | ✅ **Done** | `allowances`, `w4_step2_multiple_jobs`, `w4_dependent_credit`, `w4_step4a_other_income`, `w4_step4b_deductions` | — |
| YTD gross per employee | ✅ | ✅ **Done** | `EmployeeYtdTotal` — gross, withholding, SS, Medicare, retirement, net | — |
| YTD totals by company | ✅ | ✅ **Done** | `CompanyYtdTotal` | — |
| YTD totals by department | ✅ | ✅ **Done** | `DepartmentYtdTotal` | — |
| SS wage base cap ($176,100 for 2025, $184,500 for 2026) | ✅ | ✅ **Done** | `GuamTaxCalculatorV2` checks `ss_wage_base` from `AnnualTaxConfig`; stops withholding when YTD reaches cap | — |
| Additional Medicare Tax (0.9% over $200K) | ✅ | ✅ **Done** | `GuamTaxCalculatorV2` applies `additional_medicare_rate` on wages exceeding threshold | — |
| Employee status (active / inactive / terminated) | ✅ | ✅ **Done** | `status` field on `Employee` | — |
| Hire date / termination date | ✅ | 🟡 **Partial** | `hired_on` exists; no termination date field | Add `terminated_on` to employees; use to auto-inactivate |
| Department assignment | ✅ | ✅ **Done** | `Department` → `Employee` belongs_to | — |
| Multi-company (client payroll) | ✅ | ✅ **Done** | `company_id` scoping throughout; `current_company_id` in auth | — |
| Employee bulk import | ❌ (manual) | ✅ **Done** | CSV/Excel upload with preview, validation, duplicate detection | — |

---

## 3. Reports & Exports

| Feature | QB Has It? | Our Status | Notes | Next Actions |
|---------|-----------|------------|-------|--------------|
| Payroll register (per period, all employees) | ✅ | ✅ **Done** | JSON, CSV, and PDF export via `PayrollRegisterGenerator` | — |
| Employee pay history | ✅ | ✅ **Done** | Backend: `ReportsController#employee_pay_history`; Frontend: Reports page tile | — |
| YTD summary report (all employees) | ✅ | ✅ **Done** | Backend: `ReportsController#ytd_summary` with per-employee + company totals; Frontend: Reports page tile | — |
| Tax withholding summary (quarterly) | ✅ | ✅ **Done** | JSON, CSV, and PDF export | — |
| Dashboard / stats | ✅ | ✅ **Done** | `ReportsController#dashboard` — headcount, YTD, recent payrolls | — |
| Transmittal log | ❌ | ✅ **Done** | PDF generation with preparer info, notes, check numbers; state persisted per pay period | — |
| Full print package | ❌ | ✅ **Done** | Combined PDF of all pay period documents | — |
| General ledger export | ✅ | ❌ **Missing** | Not planned yet | Scope after core reports; needs GL account mapping config |
| QuickBooks IIF/CSV export | ✅ | ❌ **Missing** | Not planned | Low priority once fully replacing QB |
| Bank reconciliation report | ✅ | ❌ **Missing** | Not planned | Add after check printing is live |
| Garnishment / special deduction reporting | ✅ | 🟡 **Partial** | Standalone garnishment/child-support checks are supported; employee-level garnishment deduction reporting still pending | Add `GarnishmentDeduction` type/reporting to payroll deductions |

---

## 4. Tax & Compliance Outputs

| Feature | QB Has It? | Our Status | Notes | Next Actions |
|---------|-----------|------------|-------|--------------|
| DRT (Guam territorial income tax) withholding | ✅ | ✅ **Done** | `GuamTaxCalculatorV2` — database-driven tax brackets, Pub 15-T annualized method | — |
| Annualized withholding method (IRS Pub 15-T) | ✅ | ✅ **Done** | `GuamTaxCalculatorV2` — annualize → apply brackets → de-annualize; Step 2/3/4 support | — |
| Social Security withholding (employee 6.2%) | ✅ | ✅ **Done** | With SS wage base cap | — |
| Medicare withholding (employee 1.45%) | ✅ | ✅ **Done** | With Additional Medicare Tax (0.9% over $200K) | — |
| Employer SS match (6.2%) | ✅ | ✅ **Done** | `employer_social_security_tax` on `PayrollItem` | — |
| Employer Medicare match (1.45%) | ✅ | ✅ **Done** | `employer_medicare_tax` on `PayrollItem` | — |
| Tax table as database-driven data | ✅ | ✅ **Done** | `TaxBracket`, `TaxTable`, `AnnualTaxConfig`, `FilingStatusConfig` models; admin configurable | — |
| Federal Form 941 preparation for Guam employers | ✅ | 🟡 **Partial** | `Form941GuAggregator` — territory-specific line handling and liability detail; deposits, credits, balance, evidence, and correction workflow remain | Complete lines 8–14, deposit reconciliation, signer/preparer flow, evidence, and Form 941-X support |
| W-2GU annual preparation | ✅ | 🟡 **Partial** | `W2GuAggregator` + `W2GuPdfGenerator`; JSON, CSV, PDF export; preflight workflow; 2026 TP/TT/Box 14b data foundations | Validate 2026 source data, add W-3SS, EFW2, filing evidence, delivery, and corrections |
| W-2GU XML/EFW2 file (electronic filing) | ✅ | ❌ **Missing** | Not implemented | Follow after W-2GU PDF; Guam DRT accepts EFW2 format |
| 1099-NEC preparation | ✅ | 🟡 **Partial** | `Form1099NecAggregator` + PDF export; contractor employment type and year-versioned thresholds supported | Add official/e-file workflow, 2026 component reporting, evidence, and corrections |
| Form 500 / GuamTax resource links | N/A | ✅ **Done** | Links to DRT Form 500 plus GuamTax GRT/BPT filing help in standalone check workflows | — |
| ACH / direct deposit file generation (NACHA) | ✅ | ❌ **Missing** | Not implemented | Phase 2; requires bank routing/account on employee |
| Check printing (MICR / pre-printed stock) | ✅ | ✅ **Done** | Full check lifecycle: numbering, single/batch PDF, print/void/reissue, replacement check numbers, alignment test, standalone FIT/GRT/child-support/garnishment checks | — |

---

## 5. Audit Trail & History

| Feature | QB Has It? | Our Status | Notes | Next Actions |
|---------|-----------|------------|-------|--------------|
| Payroll item creation/edit history | ✅ | ✅ **Done** | `AuditLog` model + `audit_logs_controller.rb` | — |
| Tax config change history | ✅ | ✅ **Done** | `TaxConfigAuditLog` — separate model for tax table changes | — |
| Import session ledger | ❌ (no import in QB) | ✅ **Done** | `PayrollImportRecord` — status, filenames, matched/unmatched data | — |
| Audit log filtering (action, date, user) | ✅ | 🟡 **Partial** | Backend supports filtering; advanced UI filters pending | Add action-group and entity-type filters to UI |
| Audit log CSV export | ✅ | ❌ **Missing** | Listed in `FUTURE_IMPROVEMENTS.md` | Add CSV export to `audit_logs_controller.rb` — 0.5 day |
| Audit log retention policies | ✅ | ❌ **Missing** | Listed in `FUTURE_IMPROVEMENTS.md` | Define retention window (7 years per IRS); add archive/purge rake task |
| Who-ran-payroll tracking | ✅ | ✅ **Done** | `current_user` on audit logs; import records linked to user session | — |
| Rollback a pay period's import | limited | ✅ **Done** | `PayPeriod#payroll_items.destroy_all` — safe, documented in RUNBOOK | — |

---

## 6. Operational Controls

| Feature | QB Has It? | Our Status | Notes | Next Actions |
|---------|-----------|------------|-------|--------------|
| Role-based access (admin vs manager) | ✅ | ✅ **Done** | `User` roles; `BaseController` enforces access | — |
| Role/permission matrix UI | ✅ | ❌ **Missing** | Listed in `FUTURE_IMPROVEMENTS.md` | Low priority for now |
| User invitation flow | ✅ | ✅ **Done** | `UserInvitation` model + invite controller; invite email sent via Clerk | — |
| MFA enforcement | ✅ | ❌ **Missing** | Clerk supports MFA; needs policy config per company | Low priority |
| Multi-company isolation | ✅ | ✅ **Done** | `company_id` scoping; `current_company_id` in all admin routes | — |
| Pay period locking (prevent edits after commit) | ✅ | ✅ **Done** | `can_edit?` check on `PayPeriod`; `committed` status blocks edits | — |
| Tax config admin UI | ✅ | ✅ **Done** | `tax_configs_controller.rb`; DRT brackets configurable; `AnnualTaxConfig` management | — |
| Payroll email reminders | ✅ | ✅ **Done** | `PayrollReminderConfig` per company; daily job; configurable recipients, days before, pay schedule | — |
| Employee self-service portal | ✅ | ❌ **Missing** | No employee-facing UI | Phase 3 — employees view own pay stubs, update W-4GU |
| Pay stub delivery (email / portal) | ✅ | ❌ **Missing** | `PayStubGenerator` generates PDF; no delivery mechanism | Add email delivery via ActionMailer/Resend |
| API health monitoring / alerting | limited | ❌ **Missing** | No monitoring configured | Add `/health` endpoint; Sentry or Honeybadger |

---

## Priority Summary

### 🔴 High — Remaining for full QB replacement

1. **Off-cycle / bonus payroll run** — Some clients need off-cycle bonus runs
2. **Pay period comparison review** — QuickBooks-style current-vs-previous period deltas before approval
3. **Pay stub email delivery** — Replaces printing + mailing for most employees
4. **W-2GU EFW2 electronic filing** — Guam DRT accepts EFW2 format

### 🟠 Medium — Needed for Cornerstone scale-up

5. **MoSa loan ledger integration** — Optional balance-tracked loans, commit-time transactions, payoff caps
6. **QuickBooks historical import** — Snapshot import lane for full QB exit
7. **General ledger export** — Some clients need GL data for accounting software
8. **Audit log CSV export + retention** — Compliance completeness
9. **ACH / NACHA direct deposit file** — Phase 2; currently check-only

### 🟡 Lower — QoL / compliance completeness

7. Hire/termination date tracking
8. MFA enforcement per company
9. Employee self-service portal (Phase 3)
10. Garnishment deduction type
11. Role/permission matrix UI
12. Bank reconciliation report
13. API health monitoring

---

*Document owner: Leon Shimizu / Shimizu Technology*  
*Based on: PRD.md, BUILD_PLAN.md, FUTURE_IMPROVEMENTS.md, and actual code review of `api/app/`*  
*Last updated: 2026-05-24*
