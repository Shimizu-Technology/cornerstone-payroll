# frozen_string_literal: true

puts "Seeding information-return thresholds..."

source_url = "https://www.irs.gov/instructions/i1099mec"

(2020..2025).each do |tax_year|
  InformationReturnThreshold.find_or_initialize_by(form_type: "1099_nec", tax_year: tax_year).tap do |rule|
    rule.assign_attributes(
      threshold_amount: 600.00,
      source_url: source_url,
      effective_on: Date.new(tax_year, 1, 1)
    )
    rule.save!
  end
end

InformationReturnThreshold.find_or_initialize_by(form_type: "1099_nec", tax_year: 2026).tap do |rule|
  rule.assign_attributes(
    threshold_amount: 2_000.00,
    source_url: source_url,
    effective_on: Date.new(2026, 1, 1)
  )
  rule.save!
end

puts "  Seeded 1099-NEC thresholds through 2026"
