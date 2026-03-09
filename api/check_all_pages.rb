#!/usr/bin/env ruby

require 'pdf/reader'

pdf_path = '/Users/jerry/work/cornerstone-payroll/payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf'
reader = PDF::Reader.new(pdf_path)

puts "PDF has #{reader.pages.count} pages"
reader.pages.each_with_index do |page, idx|
  text = page.text
  if text.match?(/totals/i)
    puts "\nPage #{idx+1} has totals:"
    lines = text.split("\n")
    lines.each do |line|
      puts line if line.match?(/totals/i)
    end
  end
end

# Check first page more thoroughly
puts "\n=== First page analysis ==="
text = reader.pages.first.text
lines = text.split("\n")

# Look for any line with large numbers that could be totals
lines.each_with_index do |line, idx|
  # Look for lines with multiple large numbers
  numbers = line.scan(/\d[\d,]*\.\d{2}/)
  if numbers.length >= 5 && numbers.any? { |n| n.to_f > 1000 }
    puts "Line #{idx}: #{line}"
    puts "  Numbers: #{numbers.inspect}"
  end
end