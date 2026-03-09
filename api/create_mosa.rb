#!/usr/bin/env ruby

require File.expand_path('config/environment', __dir__)

puts "Creating MoSa company and employees..."

# 1. Create MoSa company
company = Company.find_or_create_by!(name: "MoSa's Joint") do |c|
  c.address_line1 = "123 Pale San Vitores Road"
  c.city = "Tamuning"
  c.state = "GU"
  c.zip = "96913"
  c.phone = "(671) 646-1040"
  c.email = "info@mosasjoint.com"
  c.pay_frequency = "biweekly"
  c.ein = "66-0000002"  # Placeholder
end

puts "Company: #{company.name} created"

# 2. Parse PDF for employee names
pdf_path = File.expand_path('../payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf', __dir__)

# Simple parser for names only
require 'pdf/reader'
reader = PDF::Reader.new(pdf_path)
text = reader.pages.first.text
lines = text.split("\n")

# Find employee rows (names with comma)
employee_names = []
lines.each do |line|
  if line.match?(/[A-Z][a-z]+,\s+[A-Z]/) && line.match?(/\d+\.\d{2}/)
    # Extract name from position 0..39
    name = line[0..39]&.strip&.gsub(/\s+/, ' ')
    employee_names << name if name && !name.match?(/total/i)
  end
end

puts "Found #{employee_names.count} employees in PDF"

# 3. Create departments for MoSa
kitchen_dept = Department.find_or_create_by!(company: company, name: "Kitchen")
joint_dept = Department.find_or_create_by!(company: company, name: "Joint")
maintenance_dept = Department.find_or_create_by!(company: company, name: "Maintenance")

# 4. Create employees (basic - we'll need more data later)
employee_names.each do |pdf_name|
  # Parse "Last, First M." format
  parts = pdf_name.split(',')
  if parts.length == 2
    last_name = parts[0].strip
    first_part = parts[1].strip
    # Extract first name (remove middle initial if present)
    first_name = first_part.split(' ').first
    
    # Default to hourly, $15 rate (will need actual rates from PDF)
    employee = Employee.find_or_create_by!(
      company: company,
      first_name: first_name,
      last_name: last_name
    ) do |e|
      e.department = kitchen_dept  # default
      e.employment_type = "hourly"
      e.pay_rate = 15.0  # placeholder - real rate = total_pay / total_hours from PDF
      e.pay_frequency = "biweekly"
      e.filing_status = "single"
      e.allowances = 0
      e.status = "active"
      e.hire_date = Date.new(2025, 1, 1)  # placeholder
    end
    
    puts "Created: #{employee.first_name} #{employee.last_name}"
  end
end

puts "\nDone. #{company.employees.count} employees created for #{company.name}"