#!/usr/bin/env ruby

require File.expand_path('config/environment', __dir__)
require 'pdf/reader'
require 'roo'

puts "Validating MoSa payroll import for Dec 15-27, 2025..."
puts "=" * 80

# 1. Parse PDF to get original totals
pdf_path = '/Users/jerry/work/cornerstone-payroll/payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf'
reader = PDF::Reader.new(pdf_path)
text = reader.pages.first.text
lines = text.split("\n")

# Find footer with totals
pdf_total_gross = nil
pdf_total_hours = nil

lines.each do |line|
  if line.match?(/^\s*Totals/i)
    # Line format: "Totals                                2580.15      7.82         -              30577.17     49.00         -               2587.97      30626.17   -"
    parts = line.scan(/\d+\.\d{2}/)
    if parts.length >= 8
      pdf_total_hours = parts[-2].to_f  # second last number
      pdf_total_gross = parts[-1].to_f  # last number
    end
  end
end

puts "PDF Footer Totals:"
puts "  Total Hours: #{pdf_total_hours}"
puts "  Total Gross Pay: $#{pdf_total_gross}"
puts ""

# 2. Parse Excel to get tip/loan totals
excel_path = '/Users/jerry/work/cornerstone-payroll/Loan and Tip Template for AC - PPE 2024.11.18 - 2024.12.01 - PAYDAY 2024.12.05 - NEW TEMPLATE.xlsx'
excel_total_tips = 0.0
excel_total_loans = 0.0

begin
  workbook = Roo::Excelx.new(excel_path)
  
  # TIPS - BOH sheet
  workbook.default_sheet = 'TIPS - BOH'
  (5..workbook.last_row).each do |row|
    tip_amount = workbook.cell(row, 6)  # Column F
    excel_total_tips += tip_amount.to_f if tip_amount.is_a?(Numeric)
  end
  
  # TIPS - FOH sheet
  workbook.default_sheet = 'TIPS - FOH'
  (5..workbook.last_row).each do |row|
    tip_amount = workbook.cell(row, 6)  # Column F
    excel_total_tips += tip_amount.to_f if tip_amount.is_a?(Numeric)
  end
  
  # LOANS (NO INSTALLMENTS) sheet
  workbook.default_sheet = 'LOANS (NO INSTALLMENTS)'
  (5..workbook.last_row).each do |row|
    loan_amount = workbook.cell(row, 6)  # Column F
    excel_total_loans += loan_amount.to_f if loan_amount.is_a?(Numeric)
  end
  
  # INSTALLMENT LOANS sheet
  workbook.default_sheet = 'INSTALLMENT LOANS'
  (5..workbook.last_row).each do |row|
    payment = workbook.cell(row, 8)  # Column H (Payment This Period)
    excel_total_loans += payment.to_f if payment.is_a?(Numeric)
  end
rescue => e
  puts "Excel parse error: #{e.message}"
end

puts "Excel Totals:"
puts "  Total Tips: $#{excel_total_tips.round(2)}"
puts "  Total Loans: $#{excel_total_loans.round(2)}"
puts ""

# 3. Get our calculated totals from DB
pay_period = PayPeriod.find(262)
items = pay_period.payroll_items

our_total_gross = items.sum(:gross_pay)
our_total_tips = items.sum(:tips)
our_total_loans = items.sum(:loan_deduction)
our_total_hours = items.sum(:hours_worked)

puts "Our Calculated Totals:"
puts "  Total Hours: #{our_total_hours.round(2)}"
puts "  Total Gross Pay: $#{our_total_gross.round(2)}"
puts "  Total Tips: $#{our_total_tips.round(2)}"
puts "  Total Loans: $#{our_total_loans.round(2)}"
puts "  Gross + Tips: $#{our_total_gross.round(2)} + $#{our_total_tips.round(2)} = $#{(our_total_gross + our_total_tips).round(2)}"
puts ""

# 4. Compare
puts "VALIDATION RESULTS:"
puts "-" * 40

# Hours comparison
hours_diff = (our_total_hours - pdf_total_hours).abs
hours_ok = hours_diff < 0.01
puts "Hours: PDF #{pdf_total_hours} vs Our #{our_total_hours.round(2)} | Diff: #{hours_diff.round(2)} #{hours_ok ? '✅' : '❌'}"

# Gross pay comparison (PDF gross should match our gross BEFORE tips)
pdf_gross_plus_tips = pdf_total_gross + excel_total_tips
our_gross_with_tips = our_total_gross  # Our gross already includes tips
gross_diff = (our_gross_with_tips - pdf_gross_plus_tips).abs
gross_ok = gross_diff < 0.01
puts "Gross+Tips: PDF #{pdf_total_gross.round(2)} + Excel #{excel_total_tips.round(2)} = $#{pdf_gross_plus_tips.round(2)} vs Our $#{our_gross_with_tips.round(2)} | Diff: $#{gross_diff.round(2)} #{gross_ok ? '✅' : '❌'}"

# Tips comparison
tips_diff = (our_total_tips - excel_total_tips).abs
tips_ok = tips_diff < 0.01
puts "Tips: Excel $#{excel_total_tips.round(2)} vs Our $#{our_total_tips.round(2)} | Diff: $#{tips_diff.round(2)} #{tips_ok ? '✅' : '❌'}"

# Loans comparison
loans_diff = (our_total_loans - excel_total_loans).abs
loans_ok = loans_diff < 0.01
puts "Loans: Excel $#{excel_total_loans.round(2)} vs Our $#{our_total_loans.round(2)} | Diff: $#{loans_diff.round(2)} #{loans_ok ? '✅' : '❌'}"

puts "-" * 40
if hours_ok && gross_ok && tips_ok && loans_ok
  puts "🎉 ALL TOTALS MATCH! Import is accurate."
else
  puts "⚠️  Some discrepancies found. Needs investigation."
end

# 5. Per-employee validation
puts "\nPer-employee validation (first 5):"
puts "-" * 60

# Parse PDF records using our service parser
begin
  require_relative 'app/services/payroll_import/revel_pdf_parser'
  pdf_records = PayrollImport::RevelPdfParser.parse(pdf_path)
  
  require_relative 'app/services/payroll_import/loan_tip_excel_parser'
  excel_records = PayrollImport::LoanTipExcelParser.parse(excel_path)
  
  puts "PDF records: #{pdf_records.count}"
  puts "Excel records: #{excel_records.count}"
  
  # Match up first few
  pdf_records.first(5).each do |pdf|
    name = pdf[:employee_name]
    puts "\n#{name}:"
    puts "  PDF: #{pdf[:regular_hours]} reg + #{pdf[:overtime_hours]} OT = #{pdf[:total_hours]} hrs, $#{pdf[:total_pay]} gross"
    
    # Find matching DB item
    item = items.joins(:employee).find_by("employees.last_name ILIKE ? OR employees.first_name ILIKE ?", 
                                          name.split(',')[0].strip, name.split(',')[1]&.strip&.split(' ')&.first)
    if item
      puts "  DB: #{item.hours_worked} hrs, $#{item.gross_pay} gross, $#{item.tips} tips, $#{item.loan_deduction} loans"
    else
      puts "  DB: Not found"
    end
  end
rescue => e
  puts "Error in per-employee validation: #{e.message}"
end