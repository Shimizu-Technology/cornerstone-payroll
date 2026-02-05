# frozen_string_literal: true

# Seeds for the new Tax Configuration Architecture
# Source: IRS Publication 15-T (2026), Tax Foundation 2026 brackets

puts "Seeding 2026 Annual Tax Configuration..."

# Create the 2026 config
config_2026 = AnnualTaxConfig.find_or_create_by!(tax_year: 2026) do |c|
  c.ss_wage_base = 184_500
  c.ss_rate = 0.062
  c.medicare_rate = 0.0145
  c.additional_medicare_rate = 0.009
  c.additional_medicare_threshold = 200_000
  c.is_active = true
end

puts "  Created AnnualTaxConfig for 2026"

# 2026 Tax Brackets (ANNUAL amounts from IRS)
TAX_DATA_2026 = {
  single: {
    standard_deduction: 16_100,
    brackets: [
      { order: 1, min: 0, max: 12_400, rate: 0.10 },
      { order: 2, min: 12_400, max: 50_400, rate: 0.12 },
      { order: 3, min: 50_400, max: 105_700, rate: 0.22 },
      { order: 4, min: 105_700, max: 201_775, rate: 0.24 },
      { order: 5, min: 201_775, max: 256_225, rate: 0.32 },
      { order: 6, min: 256_225, max: 640_600, rate: 0.35 },
      { order: 7, min: 640_600, max: nil, rate: 0.37 }
    ]
  },
  married: {
    standard_deduction: 32_200,
    brackets: [
      { order: 1, min: 0, max: 24_800, rate: 0.10 },
      { order: 2, min: 24_800, max: 100_800, rate: 0.12 },
      { order: 3, min: 100_800, max: 211_400, rate: 0.22 },
      { order: 4, min: 211_400, max: 403_550, rate: 0.24 },
      { order: 5, min: 403_550, max: 512_450, rate: 0.32 },
      { order: 6, min: 512_450, max: 768_700, rate: 0.35 },
      { order: 7, min: 768_700, max: nil, rate: 0.37 }
    ]
  },
  head_of_household: {
    standard_deduction: 24_150,
    brackets: [
      { order: 1, min: 0, max: 17_700, rate: 0.10 },
      { order: 2, min: 17_700, max: 67_450, rate: 0.12 },
      { order: 3, min: 67_450, max: 105_700, rate: 0.22 },
      { order: 4, min: 105_700, max: 201_775, rate: 0.24 },
      { order: 5, min: 201_775, max: 256_200, rate: 0.32 },
      { order: 6, min: 256_200, max: 640_600, rate: 0.35 },
      { order: 7, min: 640_600, max: nil, rate: 0.37 }
    ]
  }
}.freeze

TAX_DATA_2026.each do |filing_status, data|
  fsc = FilingStatusConfig.find_or_create_by!(
    annual_tax_config: config_2026,
    filing_status: filing_status.to_s
  ) do |f|
    f.standard_deduction = data[:standard_deduction]
  end

  # Update standard deduction if it exists
  fsc.update!(standard_deduction: data[:standard_deduction])

  puts "  Created FilingStatusConfig for #{filing_status} (std deduction: $#{data[:standard_deduction]})"

  data[:brackets].each do |bracket|
    TaxBracket.find_or_create_by!(
      filing_status_config: fsc,
      bracket_order: bracket[:order]
    ) do |b|
      b.min_income = bracket[:min]
      b.max_income = bracket[:max]
      b.rate = bracket[:rate]
    end
  end

  puts "    Created #{data[:brackets].size} tax brackets"
end

# Log the creation
TaxConfigAuditLog.log_created(config_2026, user_id: nil, ip_address: "system")

puts "✅ 2026 Tax Configuration seeded successfully!"
