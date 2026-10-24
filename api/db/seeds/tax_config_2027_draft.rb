# frozen_string_literal: true

# Checked 2026-10-24. No IRS 2027 Pub 15-T or retirement limits published at
# the sources below. Do not populate withholding/retirement from 2026.
AnnualTaxConfig.find_or_create_by!(tax_year: 2027) do |config|
  config.assign_attributes(
    ss_wage_base: 192_300,
    ss_rate: 0.062,
    medicare_rate: 0.0145,
    additional_medicare_rate: 0.009,
    additional_medicare_threshold: 200_000,
    is_active: false,
    verification_status: "draft",
    source_references: "2027 FICA only: https://www.ssa.gov/oact/COLA/cbb.html and https://www.irs.gov/taxtopics/tc751 (checked 2026-10-24). " \
      "HOLD: 2027 withholding https://www.irs.gov/publications/p15t and 401(k)/IRA limits " \
      "https://www.irs.gov/retirement-plans/cola-increases-for-dollar-limitations-on-benefits-and-contributions are not yet published."
  )
end
