#!/usr/bin/env ruby

require File.expand_path('config/environment', __dir__)

puts "============================================"
puts "FINAL VALIDATION: MoSa Dec 15–27, 2025"
puts "============================================"
puts ""

pp = PayPeriod.find(262)
items = pp.payroll_items.includes(:employee)

puts "Database:"
puts "  Employees imported: #{items.count}"
puts ""

# PDF totals (from footer)
pdf_total_hours = 2587.97
pdf_total_wages = 30626.17

# Our totals
our_hours = items.sum(:hours_worked).to_f
our_wages = items.sum(:gross_pay).to_f - items.sum(:reported_tips).to_f
our_tips  = items.sum(:reported_tips).to_f
our_loans = items.sum(:loan_deduction).to_f
our_gross = items.sum(:gross_pay).to_f
our_net   = items.sum(:net_pay).to_f

puts "PDF Footer Totals (46 employees):"
puts "  Total Hours: #{pdf_total_hours}"
puts "  Total Wages: $#{pdf_total_wages}"
puts ""

puts "Our Calculated Totals:"
puts "  Total Hours: #{our_hours.round(2)}"
puts "  Total Wages (hours × rate): $#{our_wages.round(2)}"
puts "  Total Tips: $#{our_tips.round(2)}"
puts "  Total Loan Deductions: $#{our_loans.round(2)}"
puts "  Gross Pay (wages + tips): $#{our_gross.round(2)}"
puts "  Net Pay (after taxes & loans): $#{our_net.round(2)}"
puts ""

hours_diff = (our_hours - pdf_total_hours).abs
wages_diff = (our_wages - pdf_total_wages).abs

puts "VALIDATION RESULTS:"
puts "-" * 50
puts "Hours:  #{'✅ MATCH' if hours_diff < 0.1} #{'❌ DIFF' if hours_diff >= 0.1}"
puts "       PDF: #{pdf_total_hours}  |  Ours: #{our_hours.round(2)}"
puts "       Difference: #{hours_diff.round(2)} hrs"
puts ""
puts "Wages:  #{'✅ MATCH' if wages_diff < 0.1} #{'❌ DIFF' if wages_diff >= 0.1}"
puts "       PDF: $#{pdf_total_wages}  |  Ours: $#{our_wages.round(2)}"
puts "       Difference: $#{wages_diff.round(2)}"
puts ""

if hours_diff < 0.1 && wages_diff < 0.1
  puts "🎉 PERFECT MATCH! All 46 employees imported correctly."
else
  puts "⚠️  Some discrepancies remain."
end

puts ""
puts "Tax & Deposit Summary:"
fit = items.sum(:withholding_tax).to_f
ss_emp = items.sum(:social_security_tax).to_f
med_emp = items.sum(:medicare_tax).to_f
ss_er = items.sum(:employer_social_security_tax).to_f
med_er = items.sum(:employer_medicare_tax).to_f

puts "  Employee FIT withheld:    $#{fit.round(2)}"
puts "  Employee SS (6.2%):       $#{ss_emp.round(2)}"
puts "  Employee Medicare (1.45%):$#{med_emp.round(2)}"
puts "  Employer SS match:        $#{ss_er.round(2)}"
puts "  Employer Medicare match:  $#{med_er.round(2)}"
puts "  ───────────────────────────────────────"
puts "  TOTAL DRT DEPOSIT:        $#{(fit + ss_emp + med_emp + ss_er + med_er).round(2)}"
puts ""
puts "Sample employees (first 3):"
items.first(3).each do |item|
  puts "  #{item.employee.full_name}: #{item.hours_worked} hrs, $#{item.gross_pay} gross, $#{item.tips} tips, $#{item.net_pay} net"
end