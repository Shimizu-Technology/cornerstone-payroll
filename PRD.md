# PRD: Cornerstone Payroll

**Project:** Cornerstone Payroll
**Client:** Cornerstone Tax Services (Guam)
**Author:** Jerry (drafted), Leon Shimizu (review)
**Status:** Draft
**Created:** 2026-02-04

---

## 1. Problem Statement

Cornerstone Tax Services currently processes payroll using a combination of Excel spreadsheets and QuickBooks. This workflow has significant pain points:

1. **QuickBooks doesn't natively support Guam** — Leon has to register with a mainland US address, and staff must manually remove/fix addresses on all printed checks
2. **Manual tax calculations** — Spreadsheets for computing withholdings, prone to human error
3. **No single system** — Data lives across multiple spreadsheets and QuickBooks, making reporting and auditing difficult
4. **Check printing friction** — QuickBooks is primarily used just for printing checks, which is expensive overhead for that one feature

### Why Now?

- Cornerstone wants to grow their payroll services to more clients
- The manual process doesn't scale beyond a handful of employees
- Guam-specific payroll software effectively doesn't exist (confirmed: Gusto, Check.com, ADP APIs all exclude US Territories)
- This represents a market gap and potential SaaS opportunity for Guam businesses

---

## 2. Goals

### Phase 1 — Internal Payroll (MVP)
Process payroll for Cornerstone's own 4 employees. Replace Excel + QuickBooks entirely for internal use.

**Success criteria:**
- [ ] Calculate gross pay from hours (biweekly)
- [ ] Compute all required Guam tax withholdings correctly
- [ ] Generate printable pay stubs (PDF)
- [ ] Generate printable payroll checks (PDF)
- [ ] Maintain payroll history and reporting

### Phase 2 — Client Payroll
Expand to process payroll for Cornerstone's tax clients (multiple companies).

### Phase 3 — Direct Deposit & Advanced Features
ACH direct deposit, quarterly filing reports (941-GU), W-2GU generation, bank reconciliation.

---

## 3. User Roles

| Role | Description | Permissions |
|------|-------------|-------------|
| **Admin** | Cornerstone owner/CEO | Full access — manage companies, employees, run payroll, system settings |
| **Payroll Manager** | Cornerstone staff | Run payroll, manage employees, view reports. Cannot change system settings. |
| **Employee** | Person being paid | View own pay stubs, update personal info (future: self-service portal) |

---

## 4. Guam Tax Structure

This is the core domain knowledge. Guam's tax system is defined by Section 31 of the Organic Act of Guam (1950):

> "The income tax laws in force in the United States shall be the income tax laws of Guam, substituting 'Guam' for 'United States' where applicable."

### Payroll Deductions (Employee Side)

| Deduction | Rate | Wage Base | Notes |
|-----------|------|-----------|-------|
| **Guam Territorial Income Tax** | Federal brackets | No cap | Uses IRS Publication 15-T withholding tables. Filed with Guam Dept of Revenue & Taxation, NOT the IRS. |
| **Social Security (OASDI)** | 6.2% | $168,600 (2025) | Same as federal. Stops withholding at wage base. |
| **Medicare** | 1.45% | No cap | Additional 0.9% on wages over $200K (single) |

### Employer-Side Taxes

| Tax | Rate | Wage Base | Notes |
|-----|------|-----------|-------|
| **Social Security (OASDI)** | 6.2% | $168,600 | Employer match |
| **Medicare** | 1.45% | No cap | Employer match (no additional 0.9%) |

### Key Simplification
Unlike mainland US payroll, there is **no separate state tax**. The Guam Territorial Income Tax IS the income tax. One jurisdiction, one set of brackets. This makes the tax engine dramatically simpler.

### Tax Filing
- Employers file with **Guam Department of Revenue and Taxation** (guamtax.com)
- Use Guam equivalents of federal forms (e.g., Form 941-GU instead of 941)
- W-2GU instead of W-2 at year-end
- Due dates mirror federal schedule

---

## 5. Feature Specifications

### 5.1 Employee Management

**Fields:**
- Full name (first, middle, last)
- Address (Guam format)
- SSN (encrypted at rest)
- Date of birth
- Hire date
- Employment type: `hourly` | `salary`
- Pay rate (hourly rate OR annual salary)
- Pay frequency: `biweekly` (default, expandable later)
- Filing status: `single` | `married` | `married_separate` | `head_of_household`
- Federal/Guam allowances (from W-4GU)
- Additional withholding amount (voluntary)
- Deductions (health insurance, retirement, etc.)
- Bank info (for future direct deposit)
- Status: `active` | `inactive` | `terminated`

### 5.2 Time Entry

**For hourly employees:**
- Date
- Hours worked (regular)
- Overtime hours (calculated or manual entry)
- Holiday hours
- Sick/PTO hours
- Notes

**For salary employees:**
- Auto-calculated per pay period (annual / 26 for biweekly)
- Adjustments for unpaid time off

**Overtime rules:**
- Guam follows federal FLSA: >40 hours/week = 1.5× rate
- Daily overtime not required (unlike California)

### 5.3 Payroll Processing

**Workflow:**
1. **Select pay period** — Start/end dates (biweekly)
2. **Review time entries** — All employees' hours for the period
3. **Calculate payroll** — System computes:
   - Gross pay (hours × rate, or salary ÷ 26)
   - Overtime pay (OT hours × rate × 1.5)
   - Pre-tax deductions (retirement, health insurance)
   - Guam Territorial Income Tax withholding
   - Social Security withholding
   - Medicare withholding
   - Post-tax deductions
   - Net pay
4. **Review & approve** — Manager reviews all calculations before committing
5. **Commit payroll** — Locks the pay period, generates pay stubs and checks
6. **Print checks** — Generate PDF checks for printing

**Payroll run status:** `draft` → `calculated` → `approved` → `committed`

### 5.4 Pay Stub Generation (PDF)

Each pay stub includes:
- Company name and address
- Employee name and address
- Pay period dates
- Earnings breakdown (regular, overtime, holiday, etc.)
- Deductions breakdown (taxes, insurance, retirement, etc.)
- YTD (year-to-date) totals for all categories
- Net pay

### 5.5 Check Printing (PDF)

Generate printable checks with:
- Payee name
- Date
- Amount (numeric and written)
- Company name and address
- Memo line (e.g., "Payroll 01/20-02/02/2026")
- Check number (sequential)
- Pay stub attached (bottom portion of check)

**Printing options:**
- Print on blank check stock (MICR toner for bank line — future)
- Print on pre-printed check stock (overlay payee/amount/date only)

### 5.6 Reporting

**Standard reports:**
- Payroll register (all employees for a pay period)
- Individual employee pay history
- Tax withholding summary (by quarter)
- Year-to-date totals
- Employer tax liability summary

**Future reports (Phase 2+):**
- 941-GU quarterly filing report
- W-2GU annual summary
- General ledger export

---

## 6. Technical Architecture

### Option A: Module in Cornerstone Tax (Recommended for Phase 1)
Add payroll as a module within the existing Cornerstone Tax app:
- **Backend:** Rails API (already exists at `cornerstone-tax/backend/`)
- **Frontend:** React + Vite (already exists at `cornerstone-tax/frontend/`)
- **Auth:** Clerk (already configured)
- **Database:** PostgreSQL (already running)

**Pros:** Shared auth, shared employee/client data, one deployment
**Cons:** Larger monolith, payroll concerns mixed with tax prep

### Option B: Standalone App
Separate Rails API + React frontend, own database.

**Pros:** Clean separation, independently deployable
**Cons:** Duplicate auth, need to sync employee data, more infrastructure

### Recommendation
**Start with Option A** (module in Cornerstone). The employee and client data already exists there. If payroll grows into its own SaaS product later, extract it then. Don't over-engineer upfront.

### Database Schema (New Tables)

```
pay_periods
  - id
  - company_id (FK → clients or internal)
  - start_date
  - end_date
  - pay_date
  - status: draft | calculated | approved | committed
  - created_by (FK → users)
  - approved_by (FK → users)
  - committed_at
  - timestamps

payroll_items (one per employee per pay period)
  - id
  - pay_period_id (FK)
  - employee_id (FK → users or new employees table)
  - employment_type: hourly | salary
  - pay_rate
  - regular_hours
  - overtime_hours
  - holiday_hours
  - pto_hours
  - gross_pay
  - territorial_tax (Guam income tax withheld)
  - social_security_tax
  - medicare_tax
  - additional_withholding
  - pre_tax_deductions (JSONB — itemized)
  - post_tax_deductions (JSONB — itemized)
  - net_pay
  - check_number
  - check_printed_at
  - ytd_gross
  - ytd_territorial_tax
  - ytd_social_security
  - ytd_medicare
  - ytd_net
  - timestamps

employees (if not reusing users table)
  - id
  - company_id
  - user_id (FK → users, optional)
  - first_name
  - middle_name
  - last_name
  - ssn_encrypted
  - date_of_birth
  - hire_date
  - termination_date
  - employment_type: hourly | salary
  - pay_rate
  - pay_frequency: biweekly | weekly | semimonthly | monthly
  - filing_status
  - allowances
  - additional_withholding
  - status: active | inactive | terminated
  - address_line1
  - address_line2
  - city
  - state (territory)
  - zip
  - timestamps

time_entries (for hourly employees)
  - id
  - employee_id (FK)
  - pay_period_id (FK)
  - date
  - regular_hours
  - overtime_hours
  - holiday_hours
  - pto_hours
  - notes
  - timestamps

deduction_types
  - id
  - company_id
  - name (e.g., "Health Insurance", "401k")
  - deduction_category: pre_tax | post_tax
  - default_amount
  - is_percentage: boolean
  - timestamps

employee_deductions
  - id
  - employee_id (FK)
  - deduction_type_id (FK)
  - amount
  - is_percentage: boolean
  - timestamps

tax_tables
  - id
  - tax_year
  - filing_status
  - bracket_data (JSONB — array of {min, max, rate, base_tax})
  - social_security_rate
  - social_security_wage_base
  - medicare_rate
  - additional_medicare_rate
  - additional_medicare_threshold
  - timestamps
```

### Tax Calculation Engine

The tax engine is a service class that:
1. Looks up the current year's tax table
2. Computes annualized income from the pay period
3. Applies federal/Guam withholding brackets (from IRS Pub 15-T)
4. Calculates per-period withholding
5. Handles Social Security wage base cap (stop withholding after $168,600 YTD)
6. Handles Additional Medicare Tax threshold

```ruby
# Example: GuamTaxCalculator
class GuamTaxCalculator
  def initialize(tax_year:, filing_status:, allowances:, pay_frequency:)
    @table = TaxTable.find_by(tax_year: tax_year, filing_status: filing_status)
    @pay_frequency = pay_frequency
    @periods_per_year = PAY_FREQUENCIES[pay_frequency] # biweekly = 26
    @allowance_amount = ALLOWANCE_AMOUNTS[tax_year] # per allowance per year
  end

  def calculate(gross_pay:, ytd_gross: 0, ytd_ss_tax: 0)
    # 1. Annualize
    annual_gross = gross_pay * @periods_per_year

    # 2. Subtract allowances
    taxable = annual_gross - (@allowances * @allowance_amount)

    # 3. Apply brackets
    annual_tax = apply_brackets(taxable)

    # 4. De-annualize
    territorial_tax = (annual_tax / @periods_per_year).round(2)

    # 5. Social Security (check wage base)
    ss_taxable = [gross_pay, [SS_WAGE_BASE - ytd_gross, 0].max].min
    social_security = (ss_taxable * SS_RATE).round(2)

    # 6. Medicare
    medicare = (gross_pay * MEDICARE_RATE).round(2)
    if ytd_gross + gross_pay > ADDITIONAL_MEDICARE_THRESHOLD
      additional = [gross_pay, ytd_gross + gross_pay - ADDITIONAL_MEDICARE_THRESHOLD].min
      medicare += (additional * ADDITIONAL_MEDICARE_RATE).round(2)
    end

    { territorial_tax:, social_security:, medicare: }
  end
end
```

---

## 7. Build Plan

### Phase 1: Internal Payroll MVP (Target: 2-3 weeks)

| # | Task | Priority | Effort |
|---|------|----------|--------|
| 1 | Set up project structure (models, migrations, routes) | P0 | 1 day |
| 2 | Employee management CRUD (backend + frontend) | P0 | 2 days |
| 3 | Tax table seeding (2025/2026 Guam brackets) | P0 | 0.5 day |
| 4 | Guam Tax Calculator service | P0 | 1 day |
| 5 | Time entry CRUD (backend + frontend) | P0 | 1.5 days |
| 6 | Pay period management | P0 | 1 day |
| 7 | Payroll processing engine (calculate all deductions) | P0 | 2 days |
| 8 | Payroll review/approval UI | P0 | 1.5 days |
| 9 | Pay stub PDF generation | P0 | 1 day |
| 10 | Check PDF generation | P0 | 1.5 days |
| 11 | Payroll register report | P1 | 0.5 day |
| 12 | Employee pay history report | P1 | 0.5 day |
| 13 | Tax withholding summary report | P1 | 0.5 day |
| 14 | Gate script + tests | P0 | 1 day |
| 15 | QA + bug fixes | P0 | 1 day |

**Total estimate: ~15 working days**

### Phase 2: Client Payroll (Target: +2 weeks)
- Multi-company support
- Client onboarding workflow
- Per-company settings (pay frequency, deduction types)
- Client-specific reporting

### Phase 3: Advanced Features (Target: +3-4 weeks)
- Direct deposit (ACH via Stripe or bank API)
- 941-GU quarterly filing report generation
- W-2GU annual generation
- Bank reconciliation module
- Employee self-service portal

---

## 8. Decision: Build as Module vs Standalone

**Decision: Build as a module in Cornerstone Tax (Option A)**

**Rationale:**
- Cornerstone already has User model, Clerk auth, and client management
- Employee data can be shared (tax prep needs the same info)
- Single deployment, single database
- If it grows into a SaaS product, extract later
- For 4 employees, standalone infrastructure is overkill

**Implementation:**
- New models in the existing Rails app
- New React pages/components in the existing frontend
- Payroll-specific routes under `/payroll/`
- Separate service classes for tax calculations

---

## 9. Open Questions

### 📋 Questions for Cornerstone Meeting (Feb 5, 2026)

**Current Workflow (Must Understand First)**

1. **Get a copy of the master payroll spreadsheet** — The one with multiple tabs that calculates FIT, Social Security, Medicare, etc. from hours. This is the source of truth for how they do it today, and we'll use the formulas to validate our tax calculator.
2. **How do hours get from the spreadsheet to checks?** — Is someone re-typing calculated amounts into QuickBooks? Is there a copy/paste step? An export? Understanding this handoff point tells us exactly what friction to eliminate.
3. **Do they want to keep QuickBooks for anything?** — Or are they happy to drop it entirely once payroll + check printing works in the new system? If they use QB for other accounting, we need to know what stays.

**Check Printing**

4. **What check stock do they use?** — Brand, size, format? Standard 8.5"×11" with 3-per-page? Single checks? Pre-printed (bank info already on it) or blank stock?
5. **What printer do they print checks on?** — Standard laser? MICR toner? This affects how we format the PDF output.

**Payroll Details**

6. **What deductions beyond taxes?** — Health insurance? Retirement/401k? Garnishments? Any pre-tax vs post-tax distinctions they track?
7. **Overtime policy** — Straight federal FLSA (>40 hrs/week = 1.5×), or any Guam-specific rules they follow?
8. **Holiday schedule** — Which holidays are paid? Guam has unique territorial holidays (Discovery Day, Liberation Day, etc.). Do employees get holiday pay automatically?
9. **PTO/Sick policy** — Does Cornerstone track PTO/sick time? Accrual rates? Need to incorporate that into the system?

**Data & System**

10. **Existing employee data** — Are the 4 employees already in the Cornerstone Tax app as users? Can we reuse that data or do we need to enter it fresh?
11. **Tax table source** — Where do they currently get their withholding tables/formulas? Guam Dept of Rev & Tax? IRS publications? CPA knowledge?
12. **Pay stub requirements** — Do they currently give employees pay stubs? What info do employees expect to see? Any specific format they're used to?

**Future / Scope**

13. **Multi-company timeline** — When do they want to start processing payroll for their tax clients? That affects Phase 2 urgency.
14. **Bank reconciliation priority** — How urgent is the bank reconciliation feature vs payroll? Can it wait until Phase 3?
15. **Build in Cornerstone Tax or standalone?** — PRD recommends as a module in cornerstone-tax, but this repo exists if standalone is preferred. Leon to decide.

---

## 10. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Tax calculation errors | Medium | High | Validate against manual calculations for all 4 employees. Cross-reference with IRS Pub 15-T. Build comprehensive test suite. |
| Check formatting issues | Medium | Medium | Get sample checks from Cornerstone. Test on their actual printer. Iterate. |
| Scope creep into Phase 2/3 | High | Medium | Strictly ship Phase 1 for internal use first. Don't build multi-company until internal is proven. |
| Tax table changes mid-year | Low | Medium | Store tax tables as data (not hardcoded). Easy to update when new tables are published. |
| SSN security | Low | High | Encrypt at rest with Rails encrypted attributes. Limit access to admin role only. Never log SSNs. |

---

*This PRD is a living document. Update as decisions are made and questions are answered.*
