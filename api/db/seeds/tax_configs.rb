# frozen_string_literal: true

# Seeds for the new Tax Configuration Architecture
# Source: IRS Publication 15-T (2026), Worksheet 1A and Annual Percentage Method tables
# https://www.irs.gov/publications/p15t

puts "Seeding 2026 Annual Tax Configuration..."

# Create the 2026 config
config_2026 = AnnualTaxConfig.find_or_initialize_by(tax_year: 2026)
config_2026.assign_attributes(AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES.merge(is_active: true))
config_2026.save!

puts "  Created AnnualTaxConfig for 2026"

TAX_DATA_2026 = AnnualTaxConfig::OFFICIAL_2026_WITHHOLDING

TAX_DATA_2026.each do |filing_status, data|
  fsc = FilingStatusConfig.find_or_initialize_by(
    annual_tax_config: config_2026,
    filing_status: filing_status.to_s
  )
  fsc.update!(standard_deduction: data.fetch(:adjustment))

  puts "  Created FilingStatusConfig for #{filing_status} (Worksheet 1A adjustment: $#{data.fetch(:adjustment)})"

  data.fetch(:standard).each_with_index do |(minimum, maximum, rate), index|
    bracket = TaxBracket.find_or_initialize_by(
      filing_status_config: fsc,
      bracket_order: index + 1
    )
    bracket.update!(min_income: minimum, max_income: maximum, rate: rate)
  end
  fsc.tax_brackets.where.not(bracket_order: 1..data.fetch(:standard).size).delete_all

  puts "    Created #{data.fetch(:standard).size} withholding rate brackets"
end

# Log the creation
TaxConfigAuditLog.log_created(config_2026, user_id: nil, ip_address: "system")

puts "✅ 2026 Tax Configuration seeded successfully!"
