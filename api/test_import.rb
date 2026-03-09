#!/usr/bin/env ruby

require_relative 'config/environment'

puts "Testing MoSa payroll import parsers..."

pdf_path = File.expand_path('../payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf', __dir__)
excel_path = File.expand_path('../Loan and Tip Template for AC - PPE 2024.11.18 - 2024.12.01 - PAYDAY 2024.12.05 - NEW TEMPLATE.xlsx', __dir__)

puts "PDF path: #{pdf_path}"
puts "Excel path: #{excel_path}"

puts "\n=== Parsing PDF ==="
begin
  pdf_records = PayrollImport::RevelPdfParser.parse(pdf_path)
  puts "Parsed #{pdf_records.count} employees from PDF"
  puts "First 3 records:"
  pdf_records.first(3).each do |record|
    puts "  #{record[:employee_name]}: #{record[:regular_hours]} hours, $#{record[:regular_pay]} regular, $#{record[:total_pay]} total"
  end
rescue => e
  puts "PDF parse error: #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
end

puts "\n=== Parsing Excel ==="
begin
  excel_records = PayrollImport::LoanTipExcelParser.parse(excel_path)
  puts "Parsed #{excel_records.count} employees from Excel"
  puts "First 3 records:"
  excel_records.first(3).each do |record|
    puts "  #{record[:last_name]}, #{record[:first_name]}: tips=$#{record[:total_tips]}, loan=$#{record[:loan_deduction]}, pool=#{record[:tip_pool]}"
  end
rescue => e
  puts "Excel parse error: #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
end

puts "\n=== Name Matching Test ==="
if pdf_records && excel_records
  begin
    matcher = PayrollImport::NameMatcher.new
    pdf_records.first(3).each do |pdf_record|
      match = matcher.match(pdf_record[:employee_name])
      puts "  PDF: #{pdf_record[:employee_name]} -> #{match ? "Matched employee_id #{match[:employee_id]} (confidence: #{match[:confidence]})" : "No match"}"
    end
  rescue => e
    puts "Name match error: #{e.class}: #{e.message}"
  end
end

puts "\nDone."