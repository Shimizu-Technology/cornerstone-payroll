# PRD: Cornerstone Payroll

**Project:** Cornerstone Payroll
**Client:** Cornerstone Tax Services (Guam)
**Author:** Jerry (drafted), Leon Shimizu (review)
**Status:** Draft
**Created:** 2026-02-04
**Updated:** 2026-02-06 (Tax Configuration Architecture)

---

## 0. Existing Codebase Audit — `leon-tax-calculator`

**Repos:** `Shimizu-Technology/leon-tax-calculator` (Rails API) + `Shimizu-Technology/leon-tax-calculator-frontend` (React)
**Built:** ~September 2024
**Stack:** Rails 7.1 / Ruby 3.2.3 / PostgreSQL / React 18 (CRA)

Leon previously built a working tax calculator and payroll system. Before building Cornerstone Payroll from scratch, we audited this codebase to determine what's reusable.

### What Exists (and is reusable)

**Tax Engine — `app/services/calculator.rb`** ✅ Port
- Full federal withholding brackets for single, married, head of household
- Social Security at 6.2%, Medicare at 1.45%
- Clean, stateless calculation methods
- *Needs:* Update to 2025/2026 bracket values

**Payroll Calculators — `app/services/payroll_calculator.rb`** ✅ Port
- Strategy pattern: `PayrollCalculator.for(employee, record)` dispatches to `HourlyPayrollCalculator` or `SalaryPayrollCalculator`
- Handles: gross pay, OT (1.5×), tips, retirement, Roth, withholding, SS, Medicare, custom deductions, net pay
- Calculation ordering: gross → retirement → Roth → withholding → SS → Medicare → totals → net
- *Needs:* Pay period annualization (currently calculates per-record, not annualized)

**Employee Model** ✅ Port (with modifications)
- Filing status, pay rate, hourly/salary toggle, retirement + Roth rates
- Department assignment, company association
- YTD total calculation method (sums all payroll records for a year)
- *Needs:* More fields (SSN, address, hire date, allowances, status, pay frequency)

**Payroll Record Model** ✅ Port (rename to PayrollItem)
- Hours, OT, tips, bonuses, all tax breakdowns, gross/net
- Custom columns via JSONB for flexible deductions/additions
- `before_save` callback that runs full calculation pipeline
- YTD auto-update after save
- *Needs:* Pay period association, check number, approval tracking

**Multi-Company + Department Hierarchy** ✅ Port
- Company → Department → Employee already built
- Company-level and department-level YTD totals
- Custom columns per company (flexible deduction/addition types)

**Schema Design** ✅ Port (extend)
- `employees`, `payroll_records`, `employee_ytd_totals`, `company_ytd_totals`, `department_ytd_totals`, `companies`, `departments`, `custom_columns`
- Solid foundation — extend with `pay_periods`, `time_entries`, `deduction_types`, `tax_tables`

### What's Missing (must build new)

| Feature | Notes |
|---------|-------|
| **SS wage base cap** | No check for $176,100 (2025) ceiling — keeps withholding past the cap |
| **Additional Medicare Tax** | No 0.9% surcharge on wages over $200K |
| **Pay period concept** | No pay periods — records are individual, no grouping or approval workflow |
| **Annualized withholding** | Tax brackets are applied to per-period gross, not annualized. Should annualize per IRS Pub 15-T method |
| **Allowances (W-4GU)** | No allowance deduction before withholding calculation |
| **Tax table as data** | Brackets are hardcoded in `calculator.rb`. Should be database-driven for easy updates |
| **PDF generation** | No pay stubs or check PDFs (frontend has a `CheckComponent` but it's screen-only) |
| **Approval workflow** | No draft → approved → committed flow |
| **Time entry** | Hours entered directly on payroll record. No separate time tracking |
| **Tests** | No test suite found |

### What Must Be Rebuilt

| Component | Why |
|-----------|-----|
| **Frontend (complete redo)** | CRA is deprecated. Plain CSS files. React 18. No Tailwind. No component library. Must rebuild with Vite + React 19 + Tailwind following starter-app playbook. |
| **Auth** | Basic bcrypt/JWT. Replace with WorkOS AuthKit (MFA + RBAC for payroll security). |
| **Rails version** | 7.1 → 8.x. New project, not an upgrade-in-place. |

### Decision: Hybrid Approach

**Don't start from scratch. Don't just upgrade in place.**

1. **Create a new Rails 8 API project** using the Shimizu starter-app playbook (WorkOS, PostgreSQL, proper test setup)
2. **Port the business logic** — Calculator service, PayrollCalculator strategy pattern, model structures, YTD tracking
3. **Extend the schema** — Add pay periods, time entries, tax tables, approval states, PDF generation
4. **Fix the gaps** — SS wage base cap, Additional Medicare Tax, annualized withholding, allowances
5. **Build new Vite + React 19 + Tailwind frontend** — Clean, modern, following the design guide

This gives us proven tax math + modern infrastructure. Estimated effort saved by porting: **~40% of backend work** (the hardest 40% — tax calculations and payroll logic).

---

### Tech Stack Decision

| Layer | Choice | Rationale |
|-------|--------|-----------|
| **Backend** | Rails 8 API | Complex CRUD, many models/relationships, service objects, callbacks — Rails' sweet spot. Leon + team know it. Existing code is Rails. |
| **Frontend** | React 19 + Vite + Tailwind | Modern, fast, consistent with all Shimizu Tech projects. Replaces CRA. |
| **Auth** | WorkOS AuthKit | 1M MAU free, native Ruby SDK, RBAC built-in, MFA included. Better fit for B2B than Clerk. |
| **Database** | PostgreSQL | Already proven in existing app. JSONB for flexible deductions. |
| **File Storage** | Cloudflare R2 | S3-compatible, zero egress fees, 35% cheaper storage. Works with Rails ActiveStorage. |
| **PDF Generation** | Prawn (Ruby gem) | Industry standard for programmatic PDF in Rails. Pay stubs + checks. |
| **Check Printing** | Prawn + check_writer gem | `check_writer` for amount-to-words, Prawn for layout. |
| **Deployment** | Render (API) + Netlify (frontend) | Standard Shimizu Tech deployment. |
| **Testing** | RSpec + Playwright | Backend unit/integration + frontend E2E. Gate script required. |

**Why not Go?** Go is excellent for stateless services (like Media Tools API). But payroll is a deeply relational, business-logic-heavy CRUD app — exactly where Rails shines. The existing Calculator service pattern (strategy + polymorphism) is natural in Ruby, verbose in Go.

**Why not FastAPI?** Same reasoning. Python/FastAPI is great for AI projects (HåfaGPT, Håfa Recipes). Payroll doesn't benefit from Python's ecosystem — it benefits from Rails' model layer, migrations, and conventions.

**Why not add to Cornerstone Tax?** Originally recommended in Section 8, but Leon created a **separate repo** (`cornerstone-payroll`). This is the right call — payroll has its own lifecycle, deployment needs, and may become a standalone SaaS product. Keep it clean.

**Why WorkOS over Clerk?** Payroll is B2B with sensitive financial data. WorkOS gives us: (1) MFA included free — critical for payroll security, (2) native Ruby SDK vs Clerk's JWT-only approach, (3) RBAC built-in for admin/manager/employee roles, (4) 1M free MAU vs 10K, (5) SSO/SAML ready if Cornerstone sells to enterprise clients. Clerk stays the standard for consumer-facing apps (Hafaloha, HafaPass) where embedded React components matter.

**Why Cloudflare R2 over S3?** Zero egress fees (pay stubs get downloaded frequently), 35% cheaper storage, S3-compatible API (Rails ActiveStorage works with a config change). Leon already has a Cloudflare account (tunnels). First project to use R2 — if it works well, migrate other projects over time.

---

## 0.2 TaxBusiness Folder Deep Dive (Feb 5, 2026)

Located at `/Users/jerry/shimizu-technology/TaxBusiness/`, this folder contains **real payroll data, working code, and test assets** that significantly reduce build effort.

### Folder Structure

| Path | Purpose | Reusable? |
|------|---------|-----------|
| `payroll-backend/` | Rails 7.2 API (leon-tax-calculator) | ✅ Port services + models |
| `payroll-frontend/` | React + Vite + Tailwind UI | ✅ Reference for components |
| `tax-calculator/` | Older Rails version | Reference only |
| `test_uploads/` | MoSa's real payroll data | ✅ Test data |
| `Sample_Check.png` | Pay stub format template | ✅ PDF spec |
| `QuickBooks Class/` | Training materials (74MB PDF + 33GB video) | Reference |

### test_uploads/ — Real MoSa's Payroll Data

**Data Flow:**
```
Revel POS (hours) → LoansAndTips.xlsx (tips/loans) → Master_Payroll_File.xlsx
```

| File | Contents |
|------|----------|
| `Revel.xlsx` | POS export: `full_name`, `hours_worked`, `overtime_hours`, `regular_pay`, `overtime_pay` |
| `LoansAndTips.xlsx` | 5 sheets: TIPS-BOH, TIPS-FOH, LOANS, SUMMARY — with SUMIF formulas |
| `MosasEmployees-Correct.xlsx` | Employee master: name, department, pay_rate, retirement_rate, filing_status |
| `Mosas_Payroll_PD_082924.xlsx` | Single pay period (Aug 12-25, 2024) |
| `Master_Payroll_File (1).xlsx` | Aggregated payroll data |

**Key Insights:**
- ~50 employees at MoSa's (restaurant)
- Tips split by BOH (Back of House/kitchen) vs FOH (Front of House/servers)
- Departments: Kitchen, Joint, Salary, Hourly Maintenance
- Filing statuses: mostly `single`, some `head_of_household`
- Pay rates: $9.25 - $19.00/hour
- Some employees have retirement (4-10%), most have 0%
- Loan tracking with payment notes

### Calculator.rb — Biweekly Tax Tables Already Built

The existing `calculator.rb` has **IRS Pub 15-T biweekly withholding tables**:

```ruby
TAX_TABLES = {
  single: [
    { min_income: 0, max_income: 561.99, base_tax: 0.00, rate: 0.00, threshold: 0 },
    { min_income: 562, max_income: 1007.99, base_tax: 0.00, rate: 0.10, threshold: 562 },
    { min_income: 1008, max_income: 2374.99, base_tax: 44.60, rate: 0.12, threshold: 1008 },
    { min_income: 2375, max_income: 4427.99, base_tax: 208.64, rate: 0.22, threshold: 2375 },
    { min_income: 4428, max_income: 7943.99, base_tax: 660.30, rate: 0.24, threshold: 4428 },
    { min_income: 7944, max_income: 9935.99, base_tax: 1504.14, rate: 0.32, threshold: 7944 },
    { min_income: 9936, max_income: 23997.99, base_tax: 2141.58, rate: 0.35, threshold: 9936 },
    { min_income: 23998, max_income: Float::INFINITY, base_tax: 7063.28, rate: 0.37, threshold: 23998 }
  ],
  married: [...],  // Similar structure
  head_of_household: [...]  // Similar structure
}
```

**These are per-pay-period brackets (not annual)** — exactly what we need for biweekly payroll.

### Pay Stub Format (from Sample_Check.png)

**TOP — Check Portion:**
- Payee name (left), Amount numeric (right), Date (right)
- Amount written: "One thousand two hundred eighteen and 91/100"
- Pay Period: "08/12/2024 - 08/25/2024"

**MIDDLE — Earnings + Taxes (two duplicate stubs):**

| PAY | Hours | Rate | Current | YTD |
|-----|-------|------|---------|-----|
| Regular Pay | - | 11.25 | 0.00 | 9,196.79 |
| Joint | 60.61 | 11.25 | 681.86 | 3,761.89 |
| Vacation | - | 11.25 | 0.00 | 787.50 |
| Overtime Pay | - | 16.88 | 0.00 | 87.95 |
| Paycheck Tips | - | - | 814.61 | 14,047.79 |

| TAXES | Current | YTD |
|-------|---------|-----|
| Federal Income Tax | 103.22 | 1,825.30 |
| Social Security | 92.78 | 1,728.68 |
| Medicare | 21.70 | 404.29 |

| DEDUCTIONS | Current | YTD |
|------------|---------|-----|
| Health Insurance | 0.00 | 646.98 |
| Loan | 0.00 | 60.35 |
| 401(k) After Tax | 59.86 | 1,115.27 |

| OTHER PAY | Current | YTD |
|-----------|---------|-----|
| 401(k) After Tax | 59.86 | 1,115.27 |

**BOTTOM — Summary:**
| | Current | YTD |
|---|---------|-----|
| Total Pay | $1,496.47 | $27,881.92 |
| Taxes | $217.70 | $3,958.27 |
| Deductions | $59.86 | $1,822.60 |
| **NET PAY** | **$1,218.91** | |

### Existing Frontend Components

`payroll-frontend/src/components/payroll/`:
- `check-preview-dialog.tsx` — Check/pay stub preview modal
- `record-details-dialog.tsx` — Full payroll record view
- `bulk-entry-form.tsx` — Multi-employee entry
- `single-record-form.tsx` — Individual payroll entry
- `import-form.tsx` — CSV/Excel import
- `payroll-charts.tsx` — Visualizations
- `records-lookup.tsx` — Search/filter

### Revised Effort Estimate

With TaxBusiness assets, **~50-60% is already built**:

| Category | Status | Effort Remaining |
|----------|--------|------------------|
| Tax calculation engine | ✅ Built | Update to 2025/2026 brackets |
| Payroll calculator (hourly/salary) | ✅ Built | Add SS wage cap, Additional Medicare |
| YTD tracking | ✅ Built | Port as-is |
| Employee/Company models | ✅ Built | Extend with new fields |
| Frontend components | 🟡 Partial | Rebuild with React 19 + Tailwind |
| Pay period workflow | ❌ Missing | Build new |
| PDF generation | ❌ Missing | Build new (Prawn) |
| Auth (WorkOS) | ❌ Missing | Build new |
| R2 file storage | ❌ Missing | Build new |

**Estimated remaining effort: ~40-50%** (down from original 60% estimate)

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
| **Social Security (OASDI)** | 6.2% | $176,100 (2025) | Same as federal. Stops withholding at wage base. |
| **Medicare** | 1.45% | No cap | Additional 0.9% on wages over $200K (single) |

### Employer-Side Taxes

| Tax | Rate | Wage Base | Notes |
|-----|------|-----------|-------|
| **Social Security (OASDI)** | 6.2% | $176,100 | Employer match |
| **Medicare** | 1.45% | No cap | Employer match (no additional 0.9%) |

### Key Simplification
Unlike mainland US payroll, there is **no separate state tax**. The Guam Territorial Income Tax IS the income tax. One jurisdiction, one set of brackets. This makes the tax engine dramatically simpler.

### Tax Filing
- Employers file with **Guam Department of Revenue and Taxation** (guamtax.com)
- Use Guam equivalents of federal forms (e.g., Form 941-GU instead of 941)
- W-2GU instead of W-2 at year-end
- Due dates mirror federal schedule

---

## 4.1 Tax Configuration Architecture (Added Feb 6, 2026)

**Principle: Store what IRS publishes (annual), calculate what we need (per-period)**

### Design Goals
1. **Simple annual updates** — Cornerstone staff can update tax tables in 5 minutes
2. **No developer intervention** — Admin UI for all tax configuration changes
3. **Audit trail** — Track who changed what and when
4. **Multi-year support** — System maintains history of all tax years

### What Changes Each Year
IRS publishes new values every October for the next tax year:
- **SS wage base** — e.g., $176,100 → $184,500
- **Standard deductions** — per filing status
- **Bracket thresholds** — the income cutoffs (adjust ~2-3% for inflation)

### What Almost NEVER Changes
- Tax rates (10%, 12%, 22%, 24%, 32%, 35%, 37%)
- SS rate (6.2%)
- Medicare rate (1.45%)
- Additional Medicare rate (0.9%) and threshold ($200K)
- The calculation method itself

### Database Schema

```sql
-- One row per tax year
annual_tax_configs
  - id
  - tax_year (unique, e.g., 2026)
  - ss_wage_base (e.g., 184500.00)
  - ss_rate (default 0.062)
  - medicare_rate (default 0.0145)
  - additional_medicare_rate (default 0.009)
  - additional_medicare_threshold (default 200000)
  - is_active (boolean — currently in use)
  - created_by_id, updated_by_id (audit)
  - timestamps

-- Standard deductions per filing status (3 rows per year)
filing_status_configs
  - id
  - annual_tax_config_id (FK)
  - filing_status (single | married | head_of_household)
  - standard_deduction (annual amount, e.g., 16100.00)
  - timestamps
  - unique index on [annual_tax_config_id, filing_status]

-- Tax brackets (7 rows per filing status = 21 per year)
tax_brackets
  - id
  - filing_status_config_id (FK)
  - bracket_order (1-7)
  - min_income (annual, e.g., 0)
  - max_income (annual, e.g., 12400, null = infinity)
  - rate (e.g., 0.10)
  - timestamps
  - unique index on [filing_status_config_id, bracket_order]
```

### Calculator Flow

```ruby
class GuamTaxCalculator
  def initialize(tax_year:, filing_status:, pay_frequency:)
    @config = AnnualTaxConfig.find_by!(tax_year: tax_year, is_active: true)
    @filing_config = @config.filing_status_configs.find_by!(filing_status: filing_status)
    @periods_per_year = PAY_FREQUENCIES[pay_frequency]  # biweekly = 26
  end

  def calculate(gross_pay:, ytd_gross: 0)
    # Convert annual config to per-period amounts automatically
    period_standard_deduction = @filing_config.standard_deduction / @periods_per_year
    
    # Apply standard deduction, then brackets
    taxable = gross_pay - period_standard_deduction
    withholding = calculate_from_brackets(taxable)
    
    # SS with wage base cap
    ss = calculate_social_security(gross_pay, ytd_gross)
    
    # Medicare with additional tax threshold
    medicare = calculate_medicare(gross_pay, ytd_gross)
    
    { withholding:, social_security: ss, medicare: }
  end
end
```

### Admin UI Flow

**1. Tax Years List**
```
Tax Configurations
━━━━━━━━━━━━━━━━━━
2026 ✓ Active    [Edit] [View History]
2025             [Edit] [View History]

[+ Create 2027 from 2026]
```

**2. Create New Year**
- Click "Create 2027 from 2026"
- System copies all values from 2026
- Admin updates the ~10 numbers that changed (from IRS Pub 15-T)
- Save → ready for next year's payroll

**3. Edit Year**
- Simple form with all configurable values
- Shows annual amounts (what IRS publishes)
- System auto-calculates per-period amounts

**4. Audit History**
- Every change logged with user, timestamp, old value, new value
- Immutable audit trail for compliance

### Migration from Current Schema

The current `tax_tables` table stores pre-calculated biweekly bracket data as JSONB. We will:
1. Create new normalized tables
2. Migrate existing 2026 data to new structure
3. Update calculator to read from new tables
4. Build admin UI
5. Remove old `tax_tables` table

This is a **one-time migration** that enables the simplified annual update workflow.

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

### 5.5 Check Printing (PDF Overlay on Pre-Printed Stock)

**How it works today:** Clients have their own pre-printed business checks (e.g., Bank of Guam) — the check stock already has the company name, address, bank routing/account info, lines, and formatting. QuickBooks currently prints ONLY the variable data (payee, amount, date, written amount) onto the correct positions on the pre-printed paper.

**Our approach:** Generate a PDF overlay that prints variable data at configurable positions. The PDF is mostly whitespace with text placed precisely where the pre-printed fields are.

**Variable data to print:**
- Payee name (who the check is made out to)
- Date
- Amount (numeric, e.g., "$1,234.56")
- Amount (written, e.g., "One Thousand Two Hundred Thirty-Four and 56/100")
- Memo line (e.g., "Payroll 01/20-02/02/2026")

**Configurable positioning:**
- Each field has X/Y coordinates + font size, configurable per company
- Admin can set up a "check template" by specifying where each field prints
- Include a test print feature (prints with sample data so they can verify alignment)
- Save templates per company (different banks/check stock = different positions)

**Check number:** Not printed by us — pre-printed on the check stock. We track check numbers in our system for record-keeping only (user enters the starting check number for each payroll run).

**Pay stub attachment:** Separate page or bottom tear-off portion — configurable per company's check stock format.

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

### Decision: Standalone App (Updated Feb 4)

**Standalone Rails 8 API + Vite React frontend**, in its own repo (`cornerstone-payroll`).

- **Backend:** Rails 8 API (Ruby 3.3+), ported business logic from `leon-tax-calculator`
- **Frontend:** React 19 + Vite + Tailwind CSS (new build, replaces CRA)
- **Auth:** WorkOS AuthKit (1M MAU free, native Ruby SDK, RBAC + MFA included)
- **Database:** PostgreSQL
- **PDF:** Prawn gem (pay stubs + checks)
- **Deployment:** Render (API) + Netlify (frontend)

**Why standalone (not module in Cornerstone Tax)?**
- Payroll has its own lifecycle — different release cadence than tax prep
- May become a SaaS product for Guam businesses
- Clean separation of concerns
- Independent deployment and scaling
- Employee data can sync via shared WorkOS org or API later if needed

See **Section 0 (Existing Codebase Audit)** for full tech stack rationale.

### Database Schema

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
5. Handles Social Security wage base cap (stop withholding after $176,100 YTD)
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

## 8. Decision: Standalone App (Updated Feb 4)

**Decision: Build as a standalone app in `cornerstone-payroll` repo.**

**Rationale:**
- Leon created a separate repo — signals intent for independent product
- Payroll may become a SaaS product for Guam businesses (market gap confirmed)
- Own lifecycle, deployment, and scaling needs
- Existing `leon-tax-calculator` provides 40% of backend logic to port
- Clean architecture from day one vs extracting later

**Implementation:**
- New Rails 8 API project (not added to cornerstone-tax)
- Port models/services from leon-tax-calculator (see Section 0)
- New Vite + React 19 + Tailwind frontend
- WorkOS AuthKit for auth (RBAC + MFA), Cloudflare R2 for file storage
- Standard Shimizu Tech deployment (Render + Netlify), separate PostgreSQL database

---

## 9. Meeting Prep — Questions for Cornerstone

### 📋 Priority Questions (Need answers before building)

**🔴 The Spreadsheet (Most Important)**

1. **Get a copy of the master payroll spreadsheet.** The one with multiple tabs that calculates FIT, Social Security, Medicare, etc. from hours. We'll use the actual formulas to validate our tax engine. This is non-negotiable — we need it to ensure our calculations match theirs exactly before going live.

2. **Walk through one payroll run end-to-end.** Have the CEO show the full process: hours come in → enter into spreadsheet → spreadsheet calculates taxes → amounts go into QuickBooks → checks print. Understanding every step tells us exactly what to automate.

**🔴 Check Printing (Critical for MVP)**

3. **Get a sample pre-printed check** (blank/voided is fine). We need to measure exact field positions — where does payee name go, where's the date, where's the amount (numeric + written), where's the memo line. Different banks/check printers have different layouts.

4. **What size are the checks?** Standard 8.5"×11" with check on top and two stubs below? Or single checks? Or 3-per-page? This determines the PDF template layout.

5. **What printer?** Standard office laser printer? We need to test alignment on their actual hardware. Also: do they use the same printer for all clients' checks, or do clients print their own?

6. **For their bigger clients** — does each client provide their own pre-printed check stock? Do all clients use Bank of Guam, or different banks? (Different banks = different check layouts = we need the template system to be configurable per company.)

**🟡 Payroll Details**

7. **What deductions beyond taxes?** Health insurance? Retirement/401k? Garnishments? Loan repayments? Which are pre-tax vs post-tax? (The existing Excel probably shows this — review the spreadsheet to confirm.)

8. **How do they currently handle overtime?** Standard FLSA (>40 hrs/week = 1.5×), or any special rules for certain clients?

9. **Do they currently give employees pay stubs?** If so, what format? Print? Email? What info is on them? (If they have an example, get a copy.)

10. **What's their current pay schedule?** Biweekly is confirmed — but what specific day is payday? How many days after the period ends?

**🟡 Data & Clients**

11. **How many clients do they currently process payroll for?** And how many total employees across all clients? This helps us gauge Phase 2 scope.

12. **For internal (Cornerstone's 4 employees)** — do they all get the same deductions, or does each have different insurance/retirement setups?

13. **Where do they get their tax tables/rates?** IRS Publication 15-T? CPA knowledge? Another source? We want to use the same source they trust.

**🟢 Future Planning**

14. **Timeline for client payroll expansion** — How soon after internal payroll works do they want to start processing for clients?

15. **Bank reconciliation** — How urgent is this vs payroll? Can it wait 2-3 months?

16. **Direct deposit** — Any clients asking for this? Is it a near-term need or can it wait?

### ✅ Already Decided (Don't need to ask)
- ~~Keep QuickBooks?~~ → **No, replace entirely.**
- ~~Module or standalone?~~ → **Standalone app (cornerstone-payroll).**
- ~~Check stock type?~~ → **Pre-printed (company checks with bank info already on them). We print variable data as an overlay.**

---

## 10. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Tax calculation errors | Medium | High | Validate against manual calculations for all 4 employees. Cross-reference with IRS Pub 15-T and Cornerstone's existing Excel spreadsheet. Build comprehensive test suite. |
| Check alignment issues | Medium | Medium | Get sample pre-printed checks from Cornerstone. Build configurable positioning system with test print feature. Iterate on their actual printer. |
| Scope creep into Phase 2/3 | High | Medium | Strictly ship Phase 1 for internal use first. Don't build multi-company until internal is proven. |
| Tax table changes mid-year | Low | Medium | Store tax tables as data (not hardcoded). Easy to update when new tables are published. |
| Sensitive data security | Low | High | Rails Active Record Encryption for SSNs and bank info (AES-256-GCM, same pattern as cornerstone-tax). Limit access via WorkOS RBAC. Never log sensitive fields. Audit trail for all payroll actions. |

### Security Approach

**Encryption at rest** using Rails Active Record Encryption (same pattern already proven in `cornerstone-tax`):
```ruby
class Employee < ApplicationRecord
  encrypts :ssn
  encrypts :bank_routing_number
  encrypts :bank_account_number
end
```
Requires `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, and `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` environment variables.

**Access control** via WorkOS RBAC — admin, payroll_manager, and employee roles with different permission levels.

**Audit logging** — all payroll actions (create, approve, commit, void) logged with user ID, timestamp, and action details. Immutable audit trail.

### QuickBooks Decision

**Goal: Fully replace QuickBooks.** Cornerstone wants off QuickBooks entirely — it's currently used for check printing and some reports/calculations. Our system must cover:
1. ✅ Tax calculations (from Excel spreadsheet → our tax engine)
2. ✅ Check printing (PDF overlay on pre-printed stock)
3. ✅ Payroll reports (register, YTD, tax summaries)
4. 🔮 Phase 3: Bank reconciliation (the last QB dependency)

### Configurable Design Principles

Holidays, pay schedules, and check templates should all be **configurable per company**, not hardcoded:
- **Pay frequency:** Stored per company (biweekly default, but support weekly/semi-monthly/monthly)
- **Pay day:** Configurable (e.g., "every other Friday")
- **Holidays:** Company-level holiday calendar (Guam territorial holidays as defaults, editable)
- **Check template:** Per-company field positioning for their specific pre-printed check stock
- **Deduction types:** Per-company (already designed via `deduction_types` table)

This future-proofs for Phase 2 (multi-company) without over-engineering Phase 1.

---

*This PRD is a living document. Update as decisions are made and questions are answered.*
