# Cornerstone Payroll MVP Test Report

**Test Date:** February 6, 2026
**Tester:** Jerry (AI Agent)

---

## Executive Summary

The Cornerstone Payroll MVP is largely functional with core payroll processing working correctly. However, there are **3 bugs** that need to be fixed before production deployment.

---

## ✅ Working Features

### API Endpoints

| Endpoint | Status | Notes |
|----------|--------|-------|
| GET /api/v1/admin/employees | ✅ Works | Requires `company_id` parameter |
| GET /api/v1/admin/employees/:id | ✅ Works | Returns employee with department |
| POST /api/v1/admin/employees | ✅ Works | Creates new employee |
| GET /api/v1/admin/departments | ✅ Works | Returns departments with employee count |
| POST /api/v1/admin/departments | ✅ Works | Creates department |
| GET /api/v1/admin/pay_periods | ✅ Works | Lists all pay periods with status filter |
| POST /api/v1/admin/pay_periods | ✅ Works | Creates pay period in draft status |
| POST /api/v1/admin/pay_periods/:id/run_payroll | ✅ Works | Calculates payroll with taxes |
| GET /api/v1/admin/reports/dashboard | ✅ Works | Returns stats, YTD totals, recent payrolls |
| GET /api/v1/admin/reports/payroll_register | ✅ Works | Full payroll register with breakdowns |
| GET /api/v1/admin/reports/tax_summary | ✅ Works | Tax liability summary |
| GET /api/v1/admin/tax_configs | ✅ Works | Returns 2026 tax configuration |

### Tax Calculations (Verified)

| Employee | Gross Pay | Withholding | SS Tax | Medicare | Total Deductions | Net Pay |
|----------|-----------|-------------|--------|----------|------------------|---------|
| Maria Santos (Salary $52k) | $2,000.00 | $174.77 | $124.00 | $29.00 | $327.77 | $1,672.23 |
| John Cruz (Salary $48k) | $1,846.15 | $188.92 | $114.46 | $26.77 | $330.15 | $1,516.00 |
| Ana Reyes (Hourly $18.50) | $1,480.00 | $140.91 | $91.76 | $21.46 | $254.13 | $1,225.87 |
| David Perez (Hourly $15) | $1,200.00 | $134.46 | $74.40 | $17.40 | $226.26 | $973.74 |

**Total Payroll:** $6,526.15 gross, $5,387.84 net

### Frontend UI

| Page | Status | Notes |
|------|--------|-------|
| Dashboard | ✅ Works | Shows employee count, current pay period, YTD stats |
| Employees | ✅ Works | Lists employees with search, filters, pagination |
| Departments | ✅ Works | Lists departments with employee counts |
| Pay Periods | ✅ Works | Lists pay periods with status tabs, workflow visualization |
| Run Payroll | ✅ Works | Shows gross pay, taxes, deductions breakdown |
| Reports | ✅ Works | Payroll Register and Employee Pay History options |
| Tax Configuration | ✅ Works | Shows 2026 config with SS wage base $184,500 |

### Database/Seeding

- ✅ 2026 tax configuration seeded correctly
- ✅ Tax brackets for single, married, head_of_household
- ✅ Test company (Cornerstone Tax Services) with 4 employees
- ✅ 5 total companies created (including placeholder clients)

---

## ❌ Bugs Found

### Bug 1: Payroll Items Index - Wrong Column Names (CRITICAL)

**Endpoint:** `GET /api/v1/admin/pay_periods/:id/payroll_items`

**Error:**
```
PG::UndefinedColumn: ERROR: column "federal_withholding" does not exist
```

**Location:** `app/controllers/api/v1/admin/payroll_items_controller.rb` line 13-18

**Problem:** The controller references columns that don't exist in the schema:
- `federal_withholding` → should be `withholding_tax`
- `social_security` → should be `social_security_tax`
- `medicare` → should be `medicare_tax`
- `guam_withholding` → doesn't exist (remove or use `withholding_tax`)

**Fix Required:**
```ruby
summary: {
  total_gross: @payroll_items.sum(:gross_pay),
  total_federal: @payroll_items.sum(:withholding_tax),          # Fixed
  total_social_security: @payroll_items.sum(:social_security_tax),  # Fixed
  total_medicare: @payroll_items.sum(:medicare_tax),            # Fixed
  # total_guam: 0,  # Remove or keep as static
  total_deductions: @payroll_items.sum(:total_deductions),
  total_net: @payroll_items.sum(:net_pay),
  employee_count: @payroll_items.count
}
```

---

### Bug 2: Pay Stub Generation - Missing Method (CRITICAL)

**Endpoint:** `POST /api/v1/admin/pay_stubs/:id/generate`

**Error:**
```
NoMethodError: undefined method `ssn_last_four' for an instance of Employee
```

**Location:** `app/services/pay_stub_generator.rb` line 86

**Problem:** The generator calls `employee.ssn_last_four` but the Employee model doesn't have this method. The SSN is stored as `ssn_encrypted`.

**Fix Required:** Add method to Employee model:
```ruby
def ssn_last_four
  ssn_encrypted&.last(4)
end
```

Or update pay_stub_generator.rb:
```ruby
["SSN:", "XXX-XX-#{employee.ssn_encrypted&.last(4) || '****'}"],
```

---

### Bug 3: Frontend .env API URL Configuration (FIXED)

**Problem:** The `.env` file had `VITE_API_URL=http://localhost:3000` without `/api/v1`, causing some pages (like TaxConfigs.tsx) to build double-prefixed URLs.

**Status:** Fixed during testing by:
1. Updated `.env` to include `/api/v1` suffix
2. Updated `TaxConfigs.tsx` to remove redundant `/api/v1` prefix from fetch calls

---

## ⚠️ Issues/Concerns

### 1. CORS Configuration Too Restrictive
The CORS config only allows specific localhost ports. For production, this needs to be updated to allow the actual deployed frontend domain.

**Location:** `config/initializers/cors.rb`

### 2. Tax Summary Report Shows Zero Values
The `GET /api/v1/admin/reports/tax_summary` endpoint returns zeros even though payroll has been processed. This may be because the pay period isn't "committed" yet.

### 3. No SSN Data in Test Seed
Employees created by seeds don't have SSN data, which causes `ssn_last_four: null` in API responses. Consider adding test SSNs to seeds.

### 4. YTD Totals Show Zero on Dashboard
Even after running payroll, YTD totals show $0. The YTD rollup may only happen when payroll is committed/finalized.

### 5. Company Parameter Required But Not Obvious
Many endpoints require `company_id` parameter, but the API doesn't clearly document this. For a single-tenant MVP, consider making this implicit.

---

## Screenshots

Screenshots were captured for:
1. Dashboard with employee count and pay period
2. Employees list with 4 employees
3. Departments showing Administration and Tax Services
4. Pay Periods with status filtering
5. Run Payroll showing tax breakdown
6. Reports page
7. Tax Configuration showing 2026 settings

---

## Recommendations

### Before Production:
1. **MUST FIX:** Bug 1 - Payroll Items Controller column names
2. **MUST FIX:** Bug 2 - Pay Stub Generator ssn_last_four method
3. Update CORS for production domain

### Nice to Have:
1. Add SSN data to test seeds
2. Document required parameters in API
3. Verify YTD rollup logic works on payroll commit
4. Add proper Guam tax handling if needed

---

## Test Environment

- **API:** Rails 8.1.2, Ruby 3.3.7
- **Database:** PostgreSQL
- **Frontend:** React + Vite 7.3.1
- **Auth:** Bypassed (VITE_AUTH_ENABLED=false)
