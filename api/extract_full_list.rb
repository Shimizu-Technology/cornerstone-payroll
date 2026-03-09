#!/usr/bin/env ruby

require File.expand_path('config/environment', __dir__)

pdf_path = File.expand_path('../payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf', __dir__)

# Use the actual parser
require 'pdf/reader'
require 'tempfile'

puts "Extracting full employee list from PDF..."

reader = PDF::Reader.new(pdf_path)
text = reader.pages.first.text
lines = text.split("\n")

employee_data = []
current_employee = nil

lines.each_with_index do |line, idx|
  # Look for "Total:" line - that's the end of employee section
  break if line.match?(/^\s*Total:/i)
  
  # Look for employee name pattern (Last, First)
  if line.match?(/[A-Z][a-z]+,\s+[A-Z]/) 
    # Check if line has numbers (hours/pay) - if yes, complete record
    if line.match?(/\d+\.\d{2}/)
      employee_data << line
    else
      # Might be a multi-line name, store for merging
      current_employee = line
    end
  elsif current_employee && line.match?(/\d+\.\d{2}/)
    # This line has numbers, combine with previous name
    employee_data << "#{current_employee} #{line}"
    current_employee = nil
  end
end

puts "Found #{employee_data.count} employee records:"
employee_data.each_with_index do |line, i|
  # Extract name from first 40 chars
  name = line[0..39]&.strip
  # Extract hours and pay
  hours_match = line[100..119]&.strip
  pay_match = line[240..259]&.strip
  
  puts "#{i+1}. #{name} | hours: #{hours_match} | pay: #{pay_match}" if name && name.length > 3
end

# Now parse with the actual service parser if possible
puts "\n\nTrying to use RevelPdfParser..."
begin
  require_relative 'app/services/payroll_import/revel_pdf_parser'
  records = PayrollImport::RevelPdfParser.parse(pdf_path)
  puts "Service parser found #{records.count} employees"
  puts "First 5:"
  records.first(5).each do |r|
    puts "  #{r[:employee_name]}: #{r[:regular_hours]} hrs, $#{r[:total_pay]}"
  end
rescue => e
  puts "Service parser error: #{e.message}"
end