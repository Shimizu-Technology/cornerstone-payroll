#!/usr/bin/env ruby

require 'pdf/reader'

pdf_path = '/Users/jerry/work/cornerstone-payroll/payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf'
reader = PDF::Reader.new(pdf_path)

# Get page 2 (index 1) where Purcell appears
text = reader.pages[1].text
lines = text.split("\n")

puts "Lines 60-75 from page 2:"
lines[60..75].each_with_index do |line, idx|
  line_num = 60 + idx
  puts "#{line_num.to_s.rjust(3)}: #{line}"
  
  # Show character positions
  if idx >= 7 && idx <= 10
    puts "     " + ("0123456789" * 4)[0,40]
    puts "     " + line[0,40].gsub(/ /, '_')
  end
end

puts "\n=== Trying to parse with our parser ==="
require_relative 'app/services/payroll_import/revel_pdf_parser'

records = PayrollImport::RevelPdfParser.parse(pdf_path)

puts "Total records: #{records.count}"
records.each_with_index do |rec, i|
  if rec[:employee_name].include?('Purcell') || rec[:employee_name].include?('Riley')
    puts "#{i+1}. '#{rec[:employee_name]}' - #{rec[:regular_hours]} hrs, $#{rec[:total_pay]}"
  end
end

puts "\nChecking for 'Riley' or 'Purcell' in all records:"
records.each do |rec|
  puts "Found: #{rec[:employee_name]}" if rec[:employee_name].match?(/Purcell|Riley/i)
end