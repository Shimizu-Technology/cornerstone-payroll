#!/usr/bin/env ruby

require 'bigdecimal'

puts "Testing BigDecimal rounding for Belleza, Vincent..."

# PDF data
pdf_gross = 358.32
hours = 22.4

# Float calculation (old way)
float_rate = pdf_gross / hours
float_gross = float_rate * hours
puts "Float rate: #{float_rate}"
puts "Float gross: #{float_gross}"
puts "Float diff: #{(float_gross - pdf_gross).abs}"

# BigDecimal calculation (new way)
bd_gross = BigDecimal(pdf_gross.to_s)
bd_hours = BigDecimal(hours.to_s)
bd_rate = bd_gross / bd_hours
bd_calc_gross = bd_rate * bd_hours
puts "\nBigDecimal rate: #{bd_rate.round(6)}"
puts "BigDecimal gross: #{bd_calc_gross.round(2)}"
puts "BigDecimal diff: #{(bd_calc_gross - bd_gross).abs}"

# Round rate to 6 decimals and recalc
rounded_rate = bd_rate.round(6)
recalc_gross = rounded_rate * bd_hours
puts "\nRounded rate (6): #{rounded_rate}"
puts "Recalc gross: #{recalc_gross.round(2)}"
puts "Recalc diff: #{(recalc_gross - bd_gross).abs}"

# What the PDF likely does: compute with higher precision, round final total
# Let's compute with rate = 15.9964285714...
exact_rate = bd_gross / bd_hours
puts "\nExact rate: #{exact_rate}"
puts "Exact gross: #{exact_rate * bd_hours}"

# Store rate with 6 decimals, compute gross, round to 2
stored_rate = exact_rate.round(6)
stored_gross = (stored_rate * bd_hours).round(2)
puts "\nStored rate (6 dec): #{stored_rate}"
puts "Stored gross (rounded 2): #{stored_gross}"
puts "Stored diff: #{stored_gross - pdf_gross}"

puts "\nConclusion: Using BigDecimal with 6-decimal rate and rounding gross to 2 decimals"
puts "should match PDF total exactly (within rounding)."