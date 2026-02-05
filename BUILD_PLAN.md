# BUILD_PLAN.md — Cornerstone Payroll

**Created:** 2026-02-05
**Author:** Jerry
**Status:** Ready to Execute

This is the tactical execution plan for building Cornerstone Payroll. See `PRD.md` for the "what and why" — this document covers the "how and when."

---

## Overview

**Approach:** Hybrid migration — new Rails 8 project, port proven business logic from `leon-tax-calculator`

**Source Code:**
- Port from: `/Users/jerry/shimizu-technology/TaxBusiness/payroll-backend/`
- Test data: `/Users/jerry/shimizu-technology/TaxBusiness/test_uploads/`
- Pay stub format: `/Users/jerry/shimizu-technology/TaxBusiness/Sample_Check.png`

**Target Repo:** `Shimizu-Technology/cornerstone-payroll`

---

## Phase 1: Foundation (Week 1)

### 1.1 Project Setup (CPR-1)
**Priority:** P0 | **Effort:** 1 day

- [ ] Create Rails 8 API project with PostgreSQL
- [ ] Configure for API-only mode
- [ ] Set up RSpec test framework
- [ ] Create gate script (`./scripts/gate.sh`)
- [ ] Configure Active Record Encryption for sensitive fields
- [ ] Set up Rubocop with Shimizu rules
- [ ] Initial commit to GitHub

**Commands:**
```bash
rails new cornerstone-payroll-api --api --database=postgresql -T
cd cornerstone-payroll-api
# Add rspec-rails, factory_bot_rails, faker to Gemfile
bundle install
rails generate rspec:install
```

### 1.2 WorkOS Auth Setup (CPR-22)
**Priority:** P0 | **Effort:** 1 day

- [ ] Create WorkOS account and application
- [ ] Install `workos` gem
- [ ] Create `WorkosAuth` service class
- [ ] Implement JWT verification middleware
- [ ] Create `User` model with WorkOS ID
- [ ] Set up RBAC roles: `admin`, `payroll_manager`, `employee`
- [ ] Test login flow

**Key files to create:**
- `app/services/workos_auth.rb`
- `app/controllers/concerns/workos_authenticatable.rb`
- `app/models/user.rb`

### 1.3 Database Schema (CPR-1)
**Priority:** P0 | **Effort:** 0.5 day

Port and extend schema from `payroll-backend/db/schema.rb`:

**Models to create:**
```
companies
  - name, address, location
  - created_at, updated_at

departments
  - company_id (FK)
  - name

employees
  - company_id (FK)
  - department_id (FK)
  - user_id (FK, optional)
  - first_name, middle_name, last_name
  - ssn_encrypted
  - date_of_birth, hire_date, termination_date
  - employment_type (hourly/salary)
  - pay_rate, pay_frequency
  - filing_status, allowances, additional_withholding
  - retirement_rate, roth_retirement_rate
  - status (active/inactive/terminated)
  - address fields

pay_periods
  - company_id (FK)
  - start_date, end_date, pay_date
  - status (draft/calculated/approved/committed)
  - created_by_id, approved_by_id
  - committed_at

payroll_items (renamed from payroll_records)
  - pay_period_id (FK)
  - employee_id (FK)
  - hours_worked, overtime_hours, holiday_hours, pto_hours
  - reported_tips, bonus
  - gross_pay, net_pay
  - withholding_tax, social_security_tax, medicare_tax
  - retirement_payment, roth_retirement_payment
  - loan_payment, insurance_payment
  - custom_columns_data (JSONB)
  - ytd fields
  - check_number, check_printed_at

tax_tables
  - tax_year
  - filing_status
  - pay_frequency
  - bracket_data (JSONB)
  - ss_rate, ss_wage_base
  - medicare_rate, additional_medicare_rate, additional_medicare_threshold

deduction_types
  - company_id (FK)
  - name, category (pre_tax/post_tax)
  - default_amount, is_percentage

employee_deductions
  - employee_id (FK)
  - deduction_type_id (FK)
  - amount, is_percentage

ytd_totals (employee, company, department)
  - Already designed in existing schema
```

---

## Phase 2: Tax Engine (Week 1-2)

### 2.1 Tax Table Seeding (CPR-3)
**Priority:** P0 | **Effort:** 0.5 day

- [ ] Create `tax_tables` migration
- [ ] Seed 2024 biweekly brackets (from existing `calculator.rb`)
- [ ] Seed 2025 brackets (update values from IRS Pub 15-T)
- [ ] Support multiple pay frequencies (biweekly, weekly, semi-monthly, monthly)

**Source:** Copy bracket data from `/Users/jerry/shimizu-technology/TaxBusiness/payroll-backend/app/services/calculator.rb`

### 2.2 Guam Tax Calculator (CPR-4)
**Priority:** P0 | **Effort:** 1 day

Port and enhance `Calculator` service:

```ruby
# app/services/guam_tax_calculator.rb
class GuamTaxCalculator
  def initialize(tax_year:, filing_status:, pay_frequency:, allowances: 0)
    @tax_table = TaxTable.find_by!(tax_year:, filing_status:, pay_frequency:)
    @allowances = allowances
  end

  def calculate(gross_pay:, ytd_gross: 0, ytd_ss_tax: 0)
    {
      withholding: calculate_withholding(gross_pay),
      social_security: calculate_social_security(gross_pay, ytd_gross),
      medicare: calculate_medicare(gross_pay, ytd_gross)
    }
  end

  private

  def calculate_withholding(gross_pay)
    # Apply allowance deduction first
    taxable = gross_pay - (@allowances * allowance_per_period)
    # Find bracket and calculate
  end

  def calculate_social_security(gross_pay, ytd_gross)
    # CHECK WAGE BASE CAP
    remaining_taxable = [@tax_table.ss_wage_base - ytd_gross, 0].max
    taxable = [gross_pay, remaining_taxable].min
    (taxable * @tax_table.ss_rate).round(2)
  end

  def calculate_medicare(gross_pay, ytd_gross)
    base = (gross_pay * @tax_table.medicare_rate).round(2)
    # ADDITIONAL MEDICARE TAX (0.9% over $200K)
    if ytd_gross + gross_pay > @tax_table.additional_medicare_threshold
      additional_taxable = [gross_pay, ytd_gross + gross_pay - @tax_table.additional_medicare_threshold].min
      base += (additional_taxable * @tax_table.additional_medicare_rate).round(2)
    end
    base
  end
end
```

**Fixes from original:**
- ✅ SS wage base cap ($176,100 for 2025)
- ✅ Additional Medicare Tax (0.9% over $200K)
- ✅ Allowance deduction before withholding
- ✅ Database-driven tax tables

### 2.3 Payroll Calculator (CPR-7)
**Priority:** P0 | **Effort:** 1 day

Port strategy pattern from `payroll_calculator.rb`:

```ruby
# app/services/payroll_calculator.rb
class PayrollCalculator
  def self.for(employee, payroll_item)
    case employee.employment_type
    when 'hourly' then HourlyPayrollCalculator.new(employee, payroll_item)
    when 'salary' then SalaryPayrollCalculator.new(employee, payroll_item)
    end
  end
end

# app/services/hourly_payroll_calculator.rb
class HourlyPayrollCalculator < PayrollCalculator
  def calculate
    calculate_gross_pay
    calculate_pre_tax_deductions  # retirement
    calculate_taxes               # withholding, SS, Medicare
    calculate_post_tax_deductions # Roth, loans, insurance
    calculate_net_pay
    update_ytd_totals
  end
end
```

---

## Phase 3: CRUD + UI (Week 2)

### 3.1 Employee Management (CPR-2)
**Priority:** P0 | **Effort:** 1.5 days

**Backend:**
- [ ] Employee model with validations
- [ ] EmployeesController (CRUD)
- [ ] Employee import service (from Excel)
- [ ] Tests

**Frontend:**
- [ ] Employee list page
- [ ] Employee create/edit form
- [ ] Employee detail view
- [ ] Import from Excel modal

### 3.2 Pay Period Management (CPR-6)
**Priority:** P0 | **Effort:** 1 day

**Backend:**
- [ ] PayPeriod model with state machine
- [ ] PayPeriodsController
- [ ] Workflow: `draft` → `calculated` → `approved` → `committed`
- [ ] Prevent editing after committed

**Frontend:**
- [ ] Pay period list
- [ ] Create new pay period
- [ ] Status workflow buttons

### 3.3 Time Entry (CPR-5)
**Priority:** P0 | **Effort:** 1 day

**Backend:**
- [ ] TimeEntry model (for hourly employees)
- [ ] TimeEntriesController
- [ ] Bulk entry endpoint

**Frontend:**
- [ ] Time entry grid (employees × days)
- [ ] Bulk entry form (port from `bulk-entry-form.tsx`)

---

## Phase 4: Payroll Processing (Week 2-3)

### 4.1 Payroll Processing Engine (CPR-7)
**Priority:** P0 | **Effort:** 1.5 days

- [ ] `PayrollProcessingService` — orchestrates full payroll run
- [ ] Create PayrollItems for all employees in pay period
- [ ] Calculate all deductions via `PayrollCalculator`
- [ ] Update YTD totals
- [ ] Transaction safety (rollback on error)

### 4.2 Payroll Review UI (CPR-8)
**Priority:** P0 | **Effort:** 1 day

- [ ] Review page showing all employees' calculated pay
- [ ] Edit individual items before approval
- [ ] Approve button (with confirmation)
- [ ] Commit button (locks pay period)

---

## Phase 5: PDF Generation (Week 3)

### 5.1 Pay Stub PDF (CPR-9)
**Priority:** P0 | **Effort:** 1 day

Use Prawn gem to generate pay stubs matching `Sample_Check.png` format:

```ruby
# app/services/pay_stub_generator.rb
class PayStubGenerator
  def initialize(payroll_item)
    @item = payroll_item
    @employee = payroll_item.employee
    @company = @employee.company
  end

  def generate
    Prawn::Document.new(page_size: 'LETTER') do |pdf|
      render_check_portion(pdf)
      render_pay_stub(pdf, y_offset: 400)  # First stub
      render_pay_stub(pdf, y_offset: 100)  # Second stub (duplicate)
    end.render
  end
end
```

**Sections to render:**
- PAY (Regular, Joint, Vacation, Overtime, Tips)
- TAXES (Federal, SS, Medicare)
- DEDUCTIONS (Health Insurance, Loan, 401k)
- OTHER PAY
- SUMMARY (Total Pay, Taxes, Deductions, Net Pay)
- YTD columns for each

### 5.2 Check PDF Overlay (CPR-10)
**Priority:** P0 | **Effort:** 1 day

- [ ] Create `CheckTemplate` model (configurable field positions per company)
- [ ] Check overlay generator (prints variable data only)
- [ ] Amount-to-words conversion (`check_writer` gem)
- [ ] Test print feature (verify alignment)

```ruby
# app/services/check_overlay_generator.rb
class CheckOverlayGenerator
  def initialize(payroll_item, template:)
    @item = payroll_item
    @template = template  # CheckTemplate with x/y positions
  end

  def generate
    Prawn::Document.new(page_size: 'LETTER') do |pdf|
      pdf.text_box @item.employee.full_name,
                   at: [@template.payee_x, @template.payee_y]
      pdf.text_box @item.pay_period.pay_date.strftime('%m/%d/%Y'),
                   at: [@template.date_x, @template.date_y]
      pdf.text_box format_currency(@item.net_pay),
                   at: [@template.amount_x, @template.amount_y]
      pdf.text_box amount_in_words(@item.net_pay),
                   at: [@template.written_amount_x, @template.written_amount_y]
    end.render
  end
end
```

---

## Phase 6: Reports (Week 3)

### 6.1 Payroll Register (CPR-11)
**Priority:** P1 | **Effort:** 0.5 day

- [ ] List all employees for a pay period
- [ ] Show hours, gross, taxes, deductions, net
- [ ] Totals row
- [ ] PDF export

### 6.2 Employee Pay History (CPR-12)
**Priority:** P1 | **Effort:** 0.5 day

- [ ] All payroll records for an employee
- [ ] Date range filter
- [ ] PDF export

### 6.3 Tax Withholding Summary (CPR-13)
**Priority:** P1 | **Effort:** 0.5 day

- [ ] Quarterly summary
- [ ] Federal, SS, Medicare totals
- [ ] Per-employee breakdown
- [ ] PDF export

---

## Phase 7: File Storage + Polish (Week 3-4)

### 7.1 Cloudflare R2 Setup (CPR-23)
**Priority:** P0 | **Effort:** 0.5 day

- [ ] Create R2 bucket
- [ ] Configure Rails ActiveStorage for R2
- [ ] Test file upload/download
- [ ] Store generated PDFs

### 7.2 Gate Script + Tests (CPR-14)
**Priority:** P0 | **Effort:** 1 day

- [ ] RSpec tests for all services
- [ ] Factory definitions for all models
- [ ] Gate script: `rspec + rubocop + brakeman`
- [ ] Playwright E2E tests for frontend

### 7.3 QA + Bug Fixes (CPR-15)
**Priority:** P0 | **Effort:** 1 day

- [ ] Full end-to-end testing
- [ ] Test with MoSa's data
- [ ] Validate tax calculations against existing spreadsheet
- [ ] Fix all bugs found

---

## Validation Strategy

### Tax Calculation Validation

1. **Get MoSa's real payroll data** from `test_uploads/`
2. **Run same employee through both systems:**
   - Old: `calculator.rb` (existing)
   - New: `GuamTaxCalculator` (new)
3. **Compare results** — must match exactly
4. **Document any differences** (should only be from bug fixes like SS cap)

### Example Test Case

Employee: Chad D Cruz
- Hours: 60.61
- Rate: $11.25
- Tips: $814.61
- Filing Status: single

**Expected (from Sample_Check.png):**
- Gross: ~$1,496.47
- Federal: $103.22
- SS: $92.78
- Medicare: $21.70
- Net: $1,218.91

---

## Files to Port (Checklist)

### From payroll-backend/app/services/
- [x] `calculator.rb` → `guam_tax_calculator.rb` (enhance)
- [ ] `payroll_calculator.rb` → port as-is
- [ ] `hourly_payroll_calculator.rb` → port as-is
- [ ] `salary_payroll_calculator.rb` → port as-is
- [ ] `employee_importer_service.rb` → port + update

### From payroll-backend/app/models/
- [ ] `company.rb` → port + extend
- [ ] `department.rb` → port as-is
- [ ] `employee.rb` → port + extend significantly
- [ ] `payroll_record.rb` → rename to `payroll_item.rb`, extend
- [ ] `custom_column.rb` → port as-is

### From payroll-backend/db/
- [ ] YTD totals tables → port as-is
- [ ] Custom columns tables → port as-is

### From payroll-frontend/src/components/payroll/
- [ ] `check-preview-dialog.tsx` → reference for design
- [ ] `record-details-dialog.tsx` → reference for design
- [ ] `bulk-entry-form.tsx` → reference for design
- [ ] `import-form.tsx` → reference for design

---

## Timeline Summary

| Week | Focus | Key Deliverables |
|------|-------|------------------|
| **Week 1** | Foundation | Project setup, WorkOS auth, schema, tax engine |
| **Week 2** | CRUD + Processing | Employee, pay period, time entry, payroll calculation |
| **Week 3** | PDF + Reports | Pay stubs, checks, reports, R2 storage |
| **Week 4** | Polish | Testing, QA, bug fixes, documentation |

**Total: ~4 weeks to MVP** (internal Cornerstone payroll)

---

## Questions Still Needed

Before starting, confirm with Cornerstone:

1. **Excel spreadsheet copy** — the master calculation file for validation
2. **Sample pre-printed check** — to measure field positions
3. **List of deduction types** — what do their employees have?
4. **Pay schedule** — biweekly confirmed, but what day?
5. **Holiday list** — Guam territorial holidays to handle

---

## Next Steps

1. ✅ PRD updated with TaxBusiness findings
2. ✅ BUILD_PLAN.md created (this file)
3. [ ] Update Plane tickets (CPR-1 through CPR-34) to align
4. [ ] Schedule Cornerstone meeting to get answers
5. [ ] Begin Phase 1 when ready

---

*This plan is tactical and will be updated as we progress.*
