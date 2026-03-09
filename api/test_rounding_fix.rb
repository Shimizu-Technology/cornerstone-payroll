#!/usr/bin/env ruby

require File.expand_path('config/environment', __dir__)
require 'bigdecimal'

puts "Testing rounding fix with BigDecimal..."

# 1. Clear existing data
pp = PayPeriod.find(262)
pp.payroll_items.delete_all
PayrollImportRecord.where(pay_period_id: 262).delete_all
pp.update!(status: 'draft')
puts "Cleared pay period 262"

# 2. Run import directly using the service
pdf_path = '/Users/jerry/.openclaw/workspaces/theo/payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf'
excel_path = '/Users/jerry/.openclaw/workspaces/theo/Loan and Tip Template for AC - PPE 2024.11.18 - 2024.12.01 - PAYDAY 2024.12.05 - NEW TEMPLATE.xlsx'

require_relative 'app/services/payroll_import/import_service'

service = PayrollImport::ImportService.new(pp)

puts "Parsing files..."
preview = service.preview(pdf_path: pdf_path, excel_path: excel_path)

puts "Matched: #{preview[:matched].count} employees"
puts "Applying import..."

results = service.apply!(preview)

puts "Applied: #{results[:success].count} successful, #{results[:errors].count} errors"

# 3. Validate
items = pp.payroll_items.includes(:employee)

# Get PDF totals
require_relative 'app/services/payroll_import/revel_pdf_parser'
pdf_records = PayrollImport::RevelPdfParser.parse(pdf_path)

pdf_hours = pdf_records.sum { |r| r[:total_hours] }
pdf_wages = pdf_records.sum { |r| r[:total_pay] }

our_hours = items.sum { |i| i.hours_worked.to_f + i.overtime_hours.to_f }
our_wages = items.sum { |i| i.gross_pay.to_f - i.reported_tips.to_f }

puts "\n=== Validation ==="
puts "PDF Hours:  #{pdf_hours.round(4)}"
puts "Our Hours:  #{our_hours.round(4)}"
puts "Diff:       #{(our_hours - pdf_hours).abs.round(4)}"
puts ""
puts "PDF Wages:  $#{pdf_wages.round(4)}"
puts "Our Wages:  $#{our_wages.round(4)}"
puts "Diff:       $#{(our_wages - pdf_wages).abs.round(4)}"

# Check per-employee discrepancies
max_diff = 0.0
pdf_records.each do |pdf|
  item = items.find { |i| i.employee.last_name.downcase == pdf[:employee_name].split(',')[0].strip.downcase }
  next unless item
  
  pdf_gross = pdf[:total_pay]
  our_gross = item.gross_pay.to_f - item.reported_tips.to_f
  diff = (our_gross - pdf_gross).abs
  
  max_diff = diff if diff > max_diff
  
  if diff > 0.01
    puts "  #{pdf[:employee_name][0..20]}: PDF=$#{pdf_gross.round(2)} Our=$#{our_gross.round(2)} Diff=$#{diff.round(4)}"
  end
end

puts "\nMax per-employee diff: $#{max_diff.round(4)}"

if (our_hours - pdf_hours).abs < 0.01 && (our_wages - pdf_wages).abs < 0.01
  puts "\n✅ ROUNDING FIX SUCCESSFUL — Perfect match!"
else
  puts "\n⚠️  Still some discrepancies"
end