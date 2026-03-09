#!/usr/bin/env ruby

require 'pdf/reader'

pdf_path = '/Users/jerry/work/cornerstone-payroll/payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf'
reader = PDF::Reader.new(pdf_path)

puts "Page 2 text:"
text = reader.pages[1].text
puts text

puts "\n=== Parsing page 2 lines ==="
lines = text.split("\n")
lines.each_with_index do |line, idx|
  puts "#{idx}: #{line}" if line.match?(/[A-Za-z]/) || line.match?(/\d+\.\d{2}/)
end