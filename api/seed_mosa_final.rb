#!/usr/bin/env ruby

require File.expand_path('config/environment', __dir__)

puts "Re-seeding MoSa employees from updated PDF parser (46 employees)..."

company = Company.find_by(name: "MoSa's Joint")
unless company
  puts "MoSa company not found!"
  exit 1
end

departments = {
  kitchen: Department.find_or_create_by!(company: company, name: "Kitchen"),
  joint: Department.find_or_create_by!(company: company, name: "Joint"),
  maintenance: Department.find_or_create_by!(company: company, name: "Maintenance"),
  hourly: Department.find_or_create_by!(company: company, name: "Hourly")
}

pdf_path = '/Users/jerry/work/cornerstone-payroll/payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf'

require_relative 'app/services/payroll_import/revel_pdf_parser'
records = PayrollImport::RevelPdfParser.parse(pdf_path)

puts "PDF parser found #{records.count} employees"

# Delete all existing employees for MoSa
old_count = company.employees.count
company.employees.delete_all
puts "Deleted #{old_count} old employees"

created = 0

records.each do |record|
  pdf_name = record[:employee_name]
  parts = pdf_name.split(',', 2)
  
  unless parts.length >= 2
    puts "Skipping bad name: '#{pdf_name}'"
    next
  end
  
  last_name = parts[0].strip
  first_part = parts[1].strip
  # Take entire first part (could be "First Middle")
  first_name = first_part.strip
  
  next if first_name.empty? || last_name.empty?
  
  # Calculate pay rate: regular_pay / regular_hours, fallback to total
  hours = record[:regular_hours] > 0 ? record[:regular_hours] : record[:total_hours]
  pay   = record[:regular_pay] > 0 ? record[:regular_pay] : record[:total_pay]
  rate  = hours > 0 ? (pay / hours).round(4) : 15.0
  
  # Default department
  dept = departments[:hourly]
  
  Employee.create!(
    company: company,
    first_name: first_name,
    last_name: last_name,
    department: dept,
    employment_type: "hourly",
    pay_rate: rate,
    pay_frequency: "biweekly",
    filing_status: "single",
    allowances: 0,
    status: "active",
    hire_date: Date.new(2025, 1, 1)
  )
  created += 1
  puts "Created: #{first_name} #{last_name} - $#{rate}/hr"
end

puts "\nDone: #{created} employees created"
puts "Total MoSa employees: #{company.employees.count}"

# Verify totals
total_hours = records.sum { |r| r[:total_hours] }
total_pay = records.sum { |r| r[:total_pay] }
puts "PDF totals: #{total_hours.round(2)} hrs, $#{total_pay.round(2)}"