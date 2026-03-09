#!/usr/bin/env ruby

require 'pdf/reader'

pdf_path = '/Users/jerry/work/cornerstone-payroll/payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf'
reader = PDF::Reader.new(pdf_path)
text = reader.pages.first.text
lines = text.split("\n")

puts "Total lines in PDF: #{lines.count}"
puts "\n=== Lines 30-80 (employee section) ==="

lines[30..80].each_with_index do |line, idx|
  line_num = 30 + idx
  puts "#{line_num.to_s.rjust(3)}: #{line}"
end

puts "\n=== Looking for multi-line names ==="

# Track if we're in a multi-line name
current_name = nil
lines.each_with_index do |line, idx|
  # Look for name pattern at column 0-39
  name_part = line[0..39]&.strip
  has_numbers = line.match?(/\d+\.\d{2}/)
  
  if name_part && name_part.match?(/[A-Z][a-z]+/) && !has_numbers
    # This could be start of a multi-line name
    puts "Line #{idx}: Possible name start: '#{name_part}' (no numbers)"
    current_name = name_part
  elsif current_name && has_numbers
    # This line has numbers, previous line was name
    puts "Line #{idx}: Numbers found after '#{current_name}'"
    puts "  Combined: '#{current_name} #{line[0..39]&.strip}'"
    current_name = nil
  end
end

puts "\n=== Parsing with service parser to see mismatches ==="
begin
  require_relative 'app/services/payroll_import/revel_pdf_parser'
  records = PayrollImport::RevelPdfParser.parse(pdf_path)
  
  puts "Total PDF records: #{records.count}"
  puts "\nFirst 10 problematic names:"
  
  records.each_with_index do |rec, i|
    next if i > 20
    
    name = rec[:employee_name]
    if name.end_with?(',') || name.split(',').length != 2
      puts "#{i+1}. '#{name}' -> Bad parse"
    end
  end
  
  puts "\nAll employee names from PDF:"
  records.each_with_index do |rec, i|
    puts "#{i+1}. '#{rec[:employee_name]}' - #{rec[:regular_hours]} hrs, $#{rec[:total_pay]}"
  end
  
rescue => e
  puts "Error: #{e.message}"
end