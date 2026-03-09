#!/usr/bin/env ruby

require_relative 'config/environment'
require_relative 'app/services/payroll_import/revel_pdf_parser'

pdf_path = '/Users/jerry/work/cornerstone-payroll/payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf'

puts "Testing fixed PDF parser..."
records = PayrollImport::RevelPdfParser.parse(pdf_path)

puts "Total records: #{records.count}"
puts "\nFirst 20 records:"
records.first(20).each_with_index do |rec, i|
  puts "#{i+1}. '#{rec[:employee_name]}' - #{rec[:regular_hours]} hrs, $#{rec[:total_pay]}"
end

puts "\nProblematic names check:"
records.each do |rec|
  name = rec[:employee_name]
  if name.end_with?(',') || name.split(',').length != 2
    puts "  WARNING: '#{name}' - bad format"
  end
end

puts "\nChecking for missing multi-line names:"
expected_names = [
  "Camacho, Zachary",
  "Fritz, Germickson",
  "Larimer, Sarahissa", 
  "McWhorter, Jamar",
  "Muna-Brecht, Shiloh",
  "Pleadwell, Emma",
  "Purcell, Cienna Riley",
  "Quichocho, Jared",
  "Umoumoch, Trina",
  "Worswick, Andrew"
]

expected_names.each do |expected|
  found = records.any? { |rec| rec[:employee_name].include?(expected.split(',').first) }
  puts "#{expected}: #{found ? '✅' : '❌'}"
end

# Also test the raw lines to see multi-line merging
puts "\n=== Debug: Checking line merging ==="
require 'pdf/reader'
reader = PDF::Reader.new(pdf_path)
text = reader.pages.first.text
lines = text.split("\n")

puts "Sample of lines around problematic areas:"
lines.each_with_index do |line, idx|
  if idx >= 10 && idx <= 25
    puts "#{idx}: #{line}"
  end
end