# frozen_string_literal: true
require File.expand_path('config/environment', __dir__)
require_relative 'app/services/payroll_import/revel_pdf_parser'

pdf_path = '/Users/jerry/work/cornerstone-payroll/payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf'
records = PayrollImport::RevelPdfParser.parse(pdf_path)
items   = PayPeriod.find(262).payroll_items.includes(:employee)

pdf_hours = records.sum { |r| r[:total_hours] }
pdf_wages = records.sum { |r| r[:total_pay] }

our_hours = items.sum { |i| i.hours_worked.to_f + i.overtime_hours.to_f }
our_wages = items.sum { |i| i.gross_pay.to_f - i.reported_tips.to_f }
our_tips  = items.sum(:reported_tips).to_f
our_loans = items.sum(:loan_deduction).to_f
our_net   = items.sum(:net_pay).to_f

fit = items.sum(:withholding_tax).to_f
ss  = items.sum(:social_security_tax).to_f + items.sum(:employer_social_security_tax).to_f
med = items.sum(:medicare_tax).to_f + items.sum(:employer_medicare_tax).to_f
drt = fit + ss + med

h_diff = (our_hours - pdf_hours).abs
w_diff = (our_wages - pdf_wages).abs

puts "============================================"
puts "FINAL VALIDATION -- MoSa Dec 15-27, 2025"
puts "============================================"
puts ""
puts "MATCHING:   #{items.count}/46 employees"
puts ""
puts "%-35s  %-12s  %-12s  %-s" % ["Metric", "PDF", "Ours", "Result"]
puts "-" * 72
puts "%-35s  %-12s  %-12s  %s" % [
  "Total Hours (reg + overtime)",
  pdf_hours.round(2).to_s,
  our_hours.round(2).to_s,
  h_diff < 0.1 ? "PASS (diff: #{h_diff.round(3)} hrs)" : "FAIL (diff: #{h_diff.round(2)} hrs)"
]
puts "%-35s  %-12s  %-12s  %s" % [
  "Total Wages (hours x rate)",
  "$#{pdf_wages.round(2)}",
  "$#{our_wages.round(2)}",
  w_diff < 1.0 ? "PASS (rounding $#{w_diff.round(2)})" : "FAIL ($#{w_diff.round(2)} off)"
]
puts ""
puts "Excel imports:"
puts "  Tips (taxable income):  $#{our_tips.round(2)}"
puts "  Loan deductions:        $#{our_loans.round(2)}"
puts ""
puts "Tax engine output:"
puts "  Net pay (46 employees): $#{our_net.round(2)}"
puts "  FIT withheld:           $#{fit.round(2)}"
puts "  SS (emp + employer):    $#{ss.round(2)}"
puts "  Medicare (emp + er):    $#{med.round(2)}"
puts "  DRT deposit:            $#{drt.round(2)}"
puts ""
if h_diff < 0.1 && w_diff < 1.0
  puts "VALIDATION PASSED -- Import engine accurate to within rounding."
  puts "Ready to process all 26 MoSa 2025 pay periods."
else
  puts "Some discrepancies remain -- needs investigation."
end