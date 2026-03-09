#!/usr/bin/env ruby

require File.expand_path('config/environment', __dir__)

puts "Seeding MoSa with full employee list from PDF..."

# 1. Get MoSa company
company = Company.find_by(name: "MoSa's Joint")
unless company
  puts "Creating MoSa's Joint company..."
  company = Company.create!(
    name: "MoSa's Joint",
    address_line1: "123 Pale San Vitores Road",
    city: "Tamuning",
    state: "GU",
    zip: "96913",
    phone: "(671) 646-1040",
    email: "info@mosasjoint.com",
    pay_frequency: "biweekly",
    ein: "66-0000002"
  )
end

# 2. Create departments
departments = {
  kitchen: Department.find_or_create_by!(company: company, name: "Kitchen"),
  joint: Department.find_or_create_by!(company: company, name: "Joint"),
  maintenance: Department.find_or_create_by!(company: company, name: "Maintenance"),
  salary: Department.find_or_create_by!(company: company, name: "Salary"),
  hourly: Department.find_or_create_by!(company: company, name: "Hourly")
}

# 3. Parse PDF with service parser
pdf_path = File.expand_path('../payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf', __dir__)

begin
  require_relative 'app/services/payroll_import/revel_pdf_parser'
  records = PayrollImport::RevelPdfParser.parse(pdf_path)
  puts "PDF parser returned #{records.count} employee records"
  
  # 4. Create/update employees
  records.each_with_index do |record, i|
    pdf_name = record[:employee_name]
    
    # Parse "Last, First M." format
    parts = pdf_name.split(',')
    if parts.length >= 2
      last_name = parts[0].strip
      first_part = parts[1].strip
      # Extract first name (remove middle initial and extra spaces)
      first_name = first_part.split(' ').first.strip
      
      # Skip if name is too short or problematic
      next if first_name.empty? || last_name.empty? || last_name.match?(/^\s*$/)
      
      # Calculate hourly rate (use regular pay / regular hours, fallback to total)
      hours = record[:regular_hours] > 0 ? record[:regular_hours] : record[:total_hours]
      pay = record[:regular_pay] > 0 ? record[:regular_pay] : record[:total_pay]
      hourly_rate = hours > 0 ? (pay / hours).round(2) : 15.0
      
      # Determine department based on name patterns or pay rate
      # This is a guess - in reality we'd need the Excel tip pool data
      department = if pdf_name.match?(/kitchen|boh|back/i) || record[:employee_name].match?(/torres|toreph|pedro|doctor|phillip|pascual/i)
        departments[:kitchen]
      elsif pdf_name.match?(/joint|foh|front/i) || record[:employee_name].match?(/jackson|cruz|haser|larimer|palsis|severin|shisler/i)
        departments[:joint]
      elsif pdf_name.match?(/maintenance/i) || record[:employee_name].match?(/moyer|mariano/i)
        departments[:maintenance]
      elsif hourly_rate > 25  # Likely salary
        departments[:salary]
      else
        departments[:hourly]
      end
      
      # Look for existing employee by name
      employee = Employee.find_by(
        company: company,
        first_name: first_name,
        last_name: last_name
      )
      
      if employee
        # Update existing
        employee.update!(
          department: department,
          pay_rate: hourly_rate,
          status: "active"
        )
        puts "Updated: #{first_name} #{last_name} - $#{hourly_rate}/hr - #{department.name}"
      else
        # Create new
        employee = Employee.create!(
          company: company,
          first_name: first_name,
          last_name: last_name,
          department: department,
          employment_type: "hourly",
          pay_rate: hourly_rate,
          pay_frequency: "biweekly",
          filing_status: "single",
          allowances: 0,
          status: "active",
          hire_date: Date.new(2025, 1, 1)  # placeholder
        )
        puts "Created: #{first_name} #{last_name} - $#{hourly_rate}/hr - #{department.name}"
      end
    else
      puts "Skipping unparseable name: #{pdf_name}"
    end
  end
  
  puts "\nTotal employees in MoSa: #{company.employees.count}"
  
rescue => e
  puts "Error parsing PDF: #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
end

puts "\nDone."