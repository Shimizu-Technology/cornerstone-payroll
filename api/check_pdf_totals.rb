#!/usr/bin/env ruby

require 'pdf/reader'

pdf_path = '/Users/jerry/work/cornerstone-payroll/payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf'
reader = PDF::Reader.new(pdf_path)
text = reader.pages.first.text
lines = text.split("\n")

puts "Looking for totals in PDF..."
lines.each do |line|
  if line.match?(/totals/i)
    puts "Totals line: #{line}"
    
    # Try to extract numbers
    numbers = line.scan(/\d[\d,]*\.\d{2}/)
    puts "Numbers found: #{numbers.inspect}"
    
    if numbers.length >= 2
      puts "Probable total hours: #{numbers[-2]}"
      puts "Probable total pay: #{numbers[-1]}"
    end
  end
end

# Also check for any summary section
puts "\nLast 10 lines of PDF:"
lines[-10..-1].each_with_index do |line, i|
  puts "#{lines.length - 10 + i}: #{line}"
end