#!/usr/bin/env ruby

require File.expand_path('config/environment', __dir__)

puts "Seeding MoSa with ALL employees from PDF (v2 - improved parser)..."

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

created = 0
updated = 0
skipped = 0

records.each do |record|
  pdf_name = record[:employee_name]
  parts = pdf_name.split(',')

  unless parts.length >= 2
    puts "Skipping bad name: '#{pdf_name}'"
    skipped += 1
    next
  end

  last_name = parts[0].strip
  first_part = parts[1].strip
  first_name = first_part.split(' ').first&.strip

  next if first_name.nil? || first_name.empty? || last_name.empty?

  # Calculate pay rate (regular pay / regular hours)
  hours = record[:regular_hours] > 0 ? record[:regular_hours] : record[:total_hours]
  pay   = record[:regular_pay] > 0 ? record[:regular_pay] : record[:total_pay]
  rate  = hours > 0 ? (pay / hours).round(2) : 15.0

  # Default department
  dept = departments[:hourly]

  employee = Employee.find_by(company: company, first_name: first_name, last_name: last_name)

  if employee
    employee.update!(pay_rate: rate, status: "active")
    updated += 1
    puts "Updated: #{first_name} #{last_name} - $#{rate}/hr"
  else
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
end

puts "\nDone: #{created} created, #{updated} updated, #{skipped} skipped"
puts "Total MoSa employees: #{company.employees.count}"
