#!/usr/bin/env ruby

require_relative 'config/environment'
require_relative 'app/services/payroll_import/revel_pdf_parser'

pdf_path = '/Users/jerry/work/cornerstone-payroll/payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf'

puts "All PDF records:"
records = PayrollImport::RevelPdfParser.parse(pdf_path)

records.each_with_index do |rec, i|
  puts "#{i+1}. '#{rec[:employee_name]}' - #{rec[:regular_hours]} hrs, $#{rec[:total_pay]}"
end

puts "\nTotal records: #{records.count}"
puts "Total hours: #{records.sum { |r| r[:total_hours] }.round(2)}"
puts "Total pay: $#{records.sum { |r| r[:total_pay] }.round(2)}"