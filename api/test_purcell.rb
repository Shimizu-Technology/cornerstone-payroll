#!/usr/bin/env ruby

require_relative 'config/environment'
require_relative 'app/services/payroll_import/revel_pdf_parser'

pdf_path = '/Users/jerry/work/cornerstone-payroll/payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf'
records = PayrollImport::RevelPdfParser.parse(pdf_path)

puts "Total records: #{records.count}"
puts "Looking for Purcell/Riley:"

records.each_with_index do |rec, i|
  if rec[:employee_name].match?(/Purcell|Riley/i)
    puts "#{i+1}. '#{rec[:employee_name]}' - #{rec[:regular_hours]} hrs, $#{rec[:total_pay]}"
  end
end

# List all records
puts "\nAll records:"
records.each_with_index do |rec, i|
  puts "#{i+1}. '#{rec[:employee_name]}'"
end

# Check totals
total_hours = records.sum { |r| r[:total_hours] }
total_pay = records.sum { |r| r[:total_pay] }
puts "\nTotals: #{total_hours.round(2)} hrs, $#{total_pay.round(2)}"