#!/usr/bin/env ruby

require File.expand_path('config/environment', __dir__)

# PDF totals (confirmed from page 2)
pdf_total_hours = 2587.97
pdf_total_gross = 30626.17

pp   = PayPeriod.find(262)
items = pp.payroll_items

our_hours = items.sum(:hours_worked).to_f
our_gross = items.sum(:gross_pay).to_f
our_tips  = items.sum(:tips).to_f
our_loans = items.sum(:loan_deduction).to_f
our_net   = items.sum(:net_pay).to_f

puts "======================================"
puts "VALIDATION: MoSa Dec 15-27, 2025"
puts "======================================"
puts ""
puts "Employee coverage: #{items.count}/45 imported"
puts ""

hours_delta = (our_hours - pdf_total_hours).abs
gross_delta = (our_gross - pdf_total_gross).abs

puts "%-35s  %-12s  %-12s  %s" % ['Metric', 'Expected', 'Ours', 'Result']
puts "-" * 65
puts "%-35s  %-12s  %-12s  %s" % [
  'Total Hours',
  pdf_total_hours.to_s,
  our_hours.round(2).to_s,
  hours_delta < 1.0 ? "✅ PASS (diff: #{hours_delta.round(2)})" : "❌ FAIL (diff: #{hours_delta.round(2)})"
]
puts "%-35s  %-12s  %-12s  %s" % [
  'Total Gross Pay (hours x rate)',
  "$#{pdf_total_gross}",
  "$#{our_gross.round(2)}",
  gross_delta < 5.0 ? "✅ PASS (diff: $#{gross_delta.round(2)})" : "⚠ DIFF $#{gross_delta.round(2)}"
]
puts ""

puts "Additional data from Excel:"
puts "  Tips imported:  $#{our_tips.round(2)}"
puts "  Loans imported: $#{our_loans.round(2)}"
puts ""

puts "Tax Engine Output (45 employees):"
puts "  Gross (hours × rate):     $#{our_gross.round(2)}"
puts "  Tips (taxable income):  + $#{our_tips.round(2)}"
puts "  Taxable gross:            $#{(our_gross + our_tips).round(2)}"
fit  = items.sum(:withholding_tax).to_f
ss   = items.sum(:social_security_tax).to_f
med  = items.sum(:medicare_tax).to_f
puts "  FIT withheld:           - $#{fit.round(2)}"
puts "  Social Security (emp):  - $#{ss.round(2)}"
puts "  Medicare (emp):         - $#{med.round(2)}"
puts "  Loan deductions:        - $#{our_loans.round(2)}"
puts "  ─────────────────────────────────"
puts "  Net pay (total):          $#{our_net.round(2)}"
puts ""

ess  = items.sum(:employer_social_security_tax).to_f
emed = items.sum(:employer_medicare_tax).to_f
drt  = fit + ss + med + ess + emed

puts "DRT Deposit Required:"
puts "  Employee FIT:             $#{fit.round(2)}"
puts "  Employee SS:              $#{ss.round(2)}"
puts "  Employee Medicare:        $#{med.round(2)}"
puts "  Employer SS match:        $#{ess.round(2)}"
puts "  Employer Medicare match:  $#{emed.round(2)}"
puts "  ─────────────────────────────────"
puts "  TOTAL DRT DEPOSIT:        $#{drt.round(2)}"
puts ""

# Per-employee sample
puts "Sample records (first 5):"
items.includes(:employee).order('employees.last_name').first(5).each do |item|
  puts "  %-22s  %5.2f hrs  $%8.2f gross  $%7.2f tips  $%7.2f net" % [
    item.employee.full_name,
    item.hours_worked,
    item.gross_pay,
    item.tips,
    item.net_pay
  ]
end
