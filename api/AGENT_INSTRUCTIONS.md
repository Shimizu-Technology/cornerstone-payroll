# Cornerstone Payroll API - Build Instructions

## Your Task (CPR-1, CPR-3, CPR-4)

Create a Rails 8 API for Guam payroll processing. This is Phase 1 foundation work.

## Context Files
- Read `../PRD.md` for full requirements
- Read `../BUILD_PLAN.md` for technical details

## What to Build

### 1. Rails 8 API Project
```bash
rails new . --api --database=postgresql -T --skip-git
```

Add to Gemfile:
- rspec-rails, factory_bot_rails, faker (testing)
- workos (auth - placeholder for now)
- prawn (PDF generation)
- aws-sdk-s3 (R2 storage - S3 compatible)
- rubocop, brakeman (code quality)

### 2. Database Schema (from BUILD_PLAN.md)
Create migrations for:
- companies (name, address, location)
- departments (company_id, name)
- employees (see PRD for full fields - encrypt ssn)
- pay_periods (company_id, start_date, end_date, pay_date, status)
- payroll_items (pay_period_id, employee_id, all tax/deduction fields)
- tax_tables (tax_year, filing_status, pay_frequency, bracket_data JSONB)
- deduction_types, employee_deductions
- ytd_totals tables (employee, company, department)

### 3. Models with Associations
- Company has_many :departments, has_many :employees through departments
- Employee belongs_to :department, has_many :payroll_items
- PayPeriod has_many :payroll_items, belongs_to :company
- PayrollItem belongs_to :pay_period, belongs_to :employee

### 4. Tax Tables Seeding (CPR-3)
Port the biweekly tax brackets from:
`/Users/jerry/shimizu-technology/TaxBusiness/payroll-backend/app/services/calculator.rb`

Seed for 2024 (existing) and 2025 (update values if known).

### 5. GuamTaxCalculator Service (CPR-4)
Port from `/Users/jerry/shimizu-technology/TaxBusiness/payroll-backend/app/services/calculator.rb`

**IMPORTANT FIXES to add:**
- SS wage base cap ($176,100 for 2025) - stop withholding after this
- Additional Medicare Tax (0.9% on wages over $200K)
- Allowance deduction before withholding calculation

### 6. PayrollCalculator Service
Port the strategy pattern from:
- `/Users/jerry/shimizu-technology/TaxBusiness/payroll-backend/app/services/payroll_calculator.rb`
- `/Users/jerry/shimizu-technology/TaxBusiness/payroll-backend/app/services/hourly_payroll_calculator.rb`
- `/Users/jerry/shimizu-technology/TaxBusiness/payroll-backend/app/services/salary_payroll_calculator.rb`

### 7. Gate Script
Create `./scripts/gate.sh` that runs:
- rspec
- rubocop
- brakeman --no-pager -q

### 8. Active Record Encryption
Configure for SSN and bank info fields.

## Validation
After building, test the calculator with this data:
- Employee: Fredly Fred, 56.48 hours @ $9.25, single
- Expected: Gross $522.44, SS $32.39, Medicare $7.58, Withholding $0.00, Net $482.47

## When Done
Run: `openclaw gateway wake --text "CPR-1/3/4 Done: Rails API foundation with tax calculator" --mode now`
