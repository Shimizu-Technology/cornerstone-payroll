# frozen_string_literal: true

# Cornerstone Payroll - Database Seeds
# Updated: 2026-02-06 for Guam/IRS 2026 tax tables

# Load the new Tax Configuration seeds first
load Rails.root.join("db/seeds/tax_configs.rb")

puts "\nSeeding legacy tax tables (for backward compatibility)..."

# =============================================================================
# 2026 Biweekly Tax Tables
# Source: IRS Publication 15-T (2026), Tax Foundation 2026 brackets
# Guam follows federal IRS withholding rates
# =============================================================================

# The percentage method uses: tax = base_tax + (wages - threshold) * rate
# Wages here are the biweekly amount AFTER subtracting (standard_deduction / 26)

# 2026 Annual Tax Brackets (from IRS/Tax Foundation):
# Single: 10% ($0-$12,400), 12% ($12,401-$50,400), 22% ($50,401-$105,700),
#         24% ($105,701-$201,775), 32% ($201,776-$256,225), 35% ($256,226-$640,600), 37% ($640,601+)
# Married: 10% ($0-$24,800), 12% ($24,801-$100,800), 22% ($100,801-$211,400),
#          24% ($211,401-$403,550), 32% ($403,551-$512,450), 35% ($512,451-$768,700), 37% ($768,701+)

# Standard Deductions 2026: Single $16,100, Married $32,200, HoH $24,150

# Single Filing Status - Biweekly (Annual ÷ 26)
TaxTable.find_or_create_by!(
  tax_year: 2026,
  filing_status: "single",
  pay_frequency: "biweekly"
) do |t|
  # Biweekly standard deduction: $16,100 / 26 = $619.23
  t.standard_deduction = 619.23
  t.bracket_data = [
    { min_income: 0, max_income: 476.92, base_tax: 0.00, rate: 0.10, threshold: 0 },
    { min_income: 476.93, max_income: 1938.46, base_tax: 47.69, rate: 0.12, threshold: 476.93 },
    { min_income: 1938.47, max_income: 4065.38, base_tax: 223.07, rate: 0.22, threshold: 1938.47 },
    { min_income: 4065.39, max_income: 7760.58, base_tax: 691.00, rate: 0.24, threshold: 4065.39 },
    { min_income: 7760.59, max_income: 9854.81, base_tax: 1577.84, rate: 0.32, threshold: 7760.59 },
    { min_income: 9854.82, max_income: 24638.46, base_tax: 2247.99, rate: 0.35, threshold: 9854.82 },
    { min_income: 24638.47, max_income: Float::INFINITY, base_tax: 7422.27, rate: 0.37, threshold: 24638.47 }
  ]
  t.ss_rate = 0.062
  t.ss_wage_base = 184_500  # 2026 wage base (up from $176,100 in 2025)
  t.medicare_rate = 0.0145
  t.additional_medicare_rate = 0.009
  t.additional_medicare_threshold = 200_000
  t.allowance_amount = 192.31  # Per allowance deduction (deprecated but kept for compatibility)
end

# Married Filing Status - Biweekly
TaxTable.find_or_create_by!(
  tax_year: 2026,
  filing_status: "married",
  pay_frequency: "biweekly"
) do |t|
  # Biweekly standard deduction: $32,200 / 26 = $1,238.46
  t.standard_deduction = 1238.46
  t.bracket_data = [
    { min_income: 0, max_income: 953.85, base_tax: 0.00, rate: 0.10, threshold: 0 },
    { min_income: 953.86, max_income: 3876.92, base_tax: 95.39, rate: 0.12, threshold: 953.86 },
    { min_income: 3876.93, max_income: 8130.77, base_tax: 446.06, rate: 0.22, threshold: 3876.93 },
    { min_income: 8130.78, max_income: 15521.15, base_tax: 1381.90, rate: 0.24, threshold: 8130.78 },
    { min_income: 15521.16, max_income: 19709.62, base_tax: 3155.59, rate: 0.32, threshold: 15521.16 },
    { min_income: 19709.63, max_income: 29565.38, base_tax: 4495.90, rate: 0.35, threshold: 19709.63 },
    { min_income: 29565.39, max_income: Float::INFINITY, base_tax: 7945.42, rate: 0.37, threshold: 29565.39 }
  ]
  t.ss_rate = 0.062
  t.ss_wage_base = 184_500
  t.medicare_rate = 0.0145
  t.additional_medicare_rate = 0.009
  t.additional_medicare_threshold = 250_000  # Higher threshold for married filing jointly
  t.allowance_amount = 192.31
end

# Head of Household Filing Status - Biweekly
TaxTable.find_or_create_by!(
  tax_year: 2026,
  filing_status: "head_of_household",
  pay_frequency: "biweekly"
) do |t|
  # Biweekly standard deduction: $24,150 / 26 = $928.85
  t.standard_deduction = 928.85
  t.bracket_data = [
    { min_income: 0, max_income: 680.77, base_tax: 0.00, rate: 0.10, threshold: 0 },
    { min_income: 680.78, max_income: 2594.23, base_tax: 68.08, rate: 0.12, threshold: 680.78 },
    { min_income: 2594.24, max_income: 4065.38, base_tax: 297.69, rate: 0.22, threshold: 2594.24 },
    { min_income: 4065.39, max_income: 7760.58, base_tax: 621.34, rate: 0.24, threshold: 4065.39 },
    { min_income: 7760.59, max_income: 9853.85, base_tax: 1508.19, rate: 0.32, threshold: 7760.59 },
    { min_income: 9853.86, max_income: 24638.46, base_tax: 2178.03, rate: 0.35, threshold: 9853.86 },
    { min_income: 24638.47, max_income: Float::INFINITY, base_tax: 7352.64, rate: 0.37, threshold: 24638.47 }
  ]
  t.ss_rate = 0.062
  t.ss_wage_base = 184_500
  t.medicare_rate = 0.0145
  t.additional_medicare_rate = 0.009
  t.additional_medicare_threshold = 200_000
  t.allowance_amount = 192.31
end

puts "Created #{TaxTable.count} tax tables for 2026"

# =============================================================================
# Seed Cornerstone Tax Services (the real first customer)
# =============================================================================

if Rails.env.development?
  puts "\nSeeding Cornerstone Tax Services..."

  company = Company.find_or_create_by!(name: "Cornerstone Tax Services") do |c|
    c.address_line1 = "123 Pale San Vitores Road"
    c.city = "Tamuning"
    c.state = "GU"
    c.zip = "96913"
    c.phone = "(671) 646-1040"
    c.email = "payroll@cornerstone-tax.com"
    c.pay_frequency = "biweekly"
    c.ein = "66-0000001"  # Placeholder EIN
  end

  # Departments
  admin_dept = Department.find_or_create_by!(company: company, name: "Administration")
  tax_dept = Department.find_or_create_by!(company: company, name: "Tax Services")

  # Cornerstone has 4 employees - using realistic but fake data
  employees_data = [
    {
      first_name: "Maria",
      last_name: "Santos",
      department: admin_dept,
      employment_type: "salary",
      pay_rate: 52000.00,  # Annual salary
      filing_status: "married",
      allowances: 2,
      hire_date: Date.new(2020, 3, 15)
    },
    {
      first_name: "John",
      last_name: "Cruz",
      department: tax_dept,
      employment_type: "salary",
      pay_rate: 48000.00,
      filing_status: "single",
      allowances: 1,
      hire_date: Date.new(2021, 8, 1)
    },
    {
      first_name: "Ana",
      last_name: "Reyes",
      department: tax_dept,
      employment_type: "hourly",
      pay_rate: 18.50,  # Hourly rate
      filing_status: "head_of_household",
      allowances: 1,
      hire_date: Date.new(2023, 1, 10)
    },
    {
      first_name: "David",
      last_name: "Perez",
      department: admin_dept,
      employment_type: "hourly",
      pay_rate: 15.00,
      filing_status: "single",
      allowances: 0,
      hire_date: Date.new(2024, 6, 1)
    }
  ]

  employees_data.each do |emp_data|
    Employee.find_or_create_by!(
      company: company,
      first_name: emp_data[:first_name],
      last_name: emp_data[:last_name]
    ) do |e|
      e.department = emp_data[:department]
      e.employment_type = emp_data[:employment_type]
      e.pay_rate = emp_data[:pay_rate]
      e.filing_status = emp_data[:filing_status]
      e.allowances = emp_data[:allowances]
      e.status = "active"
      e.hire_date = emp_data[:hire_date]
      # SSN would be added manually by admin (encrypted)
    end
  end

  puts "Created Cornerstone Tax Services with #{company.employees.count} employees"

  # =============================================================================
  # Seed demo payroll cycle (draft -> calculated -> approved -> committed)
  # =============================================================================

  puts "\nSeeding demo payroll cycle..."

  if PayPeriod.where(company: company).none?
    employees = company.employees.active

    def build_demo_payroll_items(pay_period, employees, period_index)
      employees.each do |employee|
        payroll_item = pay_period.payroll_items.find_or_initialize_by(employee: employee)

        payroll_item.employment_type = employee.employment_type
        payroll_item.pay_rate = employee.pay_rate

        if employee.hourly?
          payroll_item.hours_worked = period_index.zero? ? 76 : 80
          payroll_item.overtime_hours = period_index.zero? ? 4 : 0
          payroll_item.holiday_hours = 0
          payroll_item.pto_hours = period_index.zero? ? 2 : 0
        else
          payroll_item.hours_worked = 0
          payroll_item.overtime_hours = 0
          payroll_item.holiday_hours = 0
          payroll_item.pto_hours = 0
        end

        payroll_item.bonus = employee.salary? && period_index.zero? ? 250.00 : 0.00
        payroll_item.reported_tips = employee.hourly? && period_index.zero? ? 45.00 : 0.00

        payroll_item.calculate!
      end
    end

    def commit_pay_period!(pay_period)
      pay_period.update!(status: "approved", approved_by_id: nil)
      pay_period.update!(status: "committed", committed_at: Time.current)

      pay_period.payroll_items.each do |item|
        ytd = EmployeeYtdTotal.find_or_create_by!(employee: item.employee, year: pay_period.pay_date.year)
        ytd.add_payroll_item!(item)
      end
    end

    today = Date.current

    committed_period = PayPeriod.create!(
      company: company,
      start_date: today - 28,
      end_date: today - 14,
      pay_date: today - 12,
      status: "draft",
      notes: "Demo committed pay period"
    )

    build_demo_payroll_items(committed_period, employees, 0)
    committed_period.update!(status: "calculated")
    commit_pay_period!(committed_period)

    calculated_period = PayPeriod.create!(
      company: company,
      start_date: today - 14,
      end_date: today - 0,
      pay_date: today + 2,
      status: "draft",
      notes: "Demo calculated pay period"
    )

    build_demo_payroll_items(calculated_period, employees, 1)
    calculated_period.update!(status: "calculated")

    draft_period = PayPeriod.create!(
      company: company,
      start_date: today,
      end_date: today + 14,
      pay_date: today + 16,
      status: "draft",
      notes: "Demo draft pay period"
    )

    puts "Created demo pay periods: #{PayPeriod.where(company: company).count}"
  else
    puts "Pay periods already exist for #{company.name}, skipping demo payroll seed"
  end

  # =============================================================================
  # Seed placeholder companies for Cornerstone's clients (empty, ready to populate)
  # =============================================================================

  puts "\nSeeding placeholder client companies..."

  client_companies = [
    { name: "Island Bistro LLC", pay_frequency: "biweekly", city: "Dededo" },
    { name: "Pacific Auto Parts", pay_frequency: "biweekly", city: "Tamuning" },
    { name: "Guam Medical Clinic", pay_frequency: "biweekly", city: "Hagåtña" },
    { name: "Sunset Construction Co.", pay_frequency: "weekly", city: "Barrigada" }
  ]

  client_companies.each do |client_data|
    Company.find_or_create_by!(name: client_data[:name]) do |c|
      c.city = client_data[:city]
      c.state = "GU"
      c.pay_frequency = client_data[:pay_frequency]
    end
  end

  puts "Created #{Company.count} companies total (including client placeholders)"
end

puts "\n✅ Seed complete!"
