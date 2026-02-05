# frozen_string_literal: true

# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

puts "Seeding tax tables..."

# 2024 Biweekly Tax Tables (from IRS Publication 15-T)
# Source: leon-tax-calculator / calculator.rb

# Single Filing Status - Biweekly
TaxTable.find_or_create_by!(
  tax_year: 2024,
  filing_status: "single",
  pay_frequency: "biweekly"
) do |t|
  t.bracket_data = [
    { min_income: 0, max_income: 561.99, base_tax: 0.00, rate: 0.00, threshold: 0 },
    { min_income: 562, max_income: 1007.99, base_tax: 0.00, rate: 0.10, threshold: 562 },
    { min_income: 1008, max_income: 2374.99, base_tax: 44.60, rate: 0.12, threshold: 1008 },
    { min_income: 2375, max_income: 4427.99, base_tax: 208.64, rate: 0.22, threshold: 2375 },
    { min_income: 4428, max_income: 7943.99, base_tax: 660.30, rate: 0.24, threshold: 4428 },
    { min_income: 7944, max_income: 9935.99, base_tax: 1504.14, rate: 0.32, threshold: 7944 },
    { min_income: 9936, max_income: 23997.99, base_tax: 2141.58, rate: 0.35, threshold: 9936 },
    { min_income: 23998, max_income: Float::INFINITY, base_tax: 7063.28, rate: 0.37, threshold: 23998 }
  ]
  t.ss_rate = 0.062
  t.ss_wage_base = 168_600 # 2024 wage base
  t.medicare_rate = 0.0145
  t.additional_medicare_rate = 0.009
  t.additional_medicare_threshold = 200_000
  t.allowance_amount = 192.31 # $5000/26 approximately
end

# Married Filing Status - Biweekly
TaxTable.find_or_create_by!(
  tax_year: 2024,
  filing_status: "married",
  pay_frequency: "biweekly"
) do |t|
  t.bracket_data = [
    { min_income: 0, max_income: 1122.99, base_tax: 0.00, rate: 0.00, threshold: 0 },
    { min_income: 1123, max_income: 2014.99, base_tax: 0.00, rate: 0.10, threshold: 1123 },
    { min_income: 2015, max_income: 4749.99, base_tax: 89.20, rate: 0.12, threshold: 2015 },
    { min_income: 4750, max_income: 8855.99, base_tax: 417.40, rate: 0.22, threshold: 4750 },
    { min_income: 8856, max_income: 15887.99, base_tax: 1320.72, rate: 0.24, threshold: 8856 },
    { min_income: 15888, max_income: 19870.99, base_tax: 3008.40, rate: 0.32, threshold: 15888 },
    { min_income: 19871, max_income: 29245.99, base_tax: 4282.96, rate: 0.35, threshold: 19871 },
    { min_income: 29246, max_income: Float::INFINITY, base_tax: 7564.21, rate: 0.37, threshold: 29246 }
  ]
  t.ss_rate = 0.062
  t.ss_wage_base = 168_600
  t.medicare_rate = 0.0145
  t.additional_medicare_rate = 0.009
  t.additional_medicare_threshold = 200_000 # $250K for married filing jointly
  t.allowance_amount = 192.31
end

# Head of Household Filing Status - Biweekly
TaxTable.find_or_create_by!(
  tax_year: 2024,
  filing_status: "head_of_household",
  pay_frequency: "biweekly"
) do |t|
  t.bracket_data = [
    { min_income: 0, max_income: 841.99, base_tax: 0.00, rate: 0.00, threshold: 0 },
    { min_income: 842, max_income: 1478.99, base_tax: 0.00, rate: 0.10, threshold: 842 },
    { min_income: 1479, max_income: 3268.99, base_tax: 63.70, rate: 0.12, threshold: 1479 },
    { min_income: 3269, max_income: 4707.99, base_tax: 278.50, rate: 0.22, threshold: 3269 },
    { min_income: 4708, max_income: 8224.99, base_tax: 595.08, rate: 0.24, threshold: 4708 },
    { min_income: 8225, max_income: 10214.99, base_tax: 1439.16, rate: 0.32, threshold: 8225 },
    { min_income: 10215, max_income: 24278.99, base_tax: 2075.96, rate: 0.35, threshold: 10215 },
    { min_income: 24279, max_income: Float::INFINITY, base_tax: 6998.36, rate: 0.37, threshold: 24279 }
  ]
  t.ss_rate = 0.062
  t.ss_wage_base = 168_600
  t.medicare_rate = 0.0145
  t.additional_medicare_rate = 0.009
  t.additional_medicare_threshold = 200_000
  t.allowance_amount = 192.31
end

puts "Created #{TaxTable.count} tax tables for 2024"

# Seed a test company for development
if Rails.env.development?
  puts "Seeding test company for development..."

  company = Company.find_or_create_by!(name: "Cornerstone Tax Services") do |c|
    c.address_line1 = "123 Tax Street"
    c.city = "Hagåtña"
    c.state = "GU"
    c.zip = "96910"
    c.phone = "(671) 555-0100"
    c.email = "payroll@cornerstone-tax.com"
    c.pay_frequency = "biweekly"
  end

  dept = Department.find_or_create_by!(company: company, name: "Administration")

  # Create a test employee
  Employee.find_or_create_by!(
    company: company,
    first_name: "Fredly",
    last_name: "Fred"
  ) do |e|
    e.department = dept
    e.employment_type = "hourly"
    e.pay_rate = 9.25
    e.filing_status = "single"
    e.allowances = 0
    e.status = "active"
    e.hire_date = Date.new(2024, 1, 1)
  end

  puts "Created test company with #{company.employees.count} employee(s)"
end

puts "Seed complete!"
