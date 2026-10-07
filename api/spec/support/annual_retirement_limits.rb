# frozen_string_literal: true

# Known published years used by historical calculator fixtures. Missing-rule
# tests delete their specific year explicitly; future years stay unconfigured.
RSpec.configure do |config|
  config.before do
    next unless defined?(AnnualRetirementLimit)

    {
      2024 => [ 23_000, 7_500, 7_500, 145_000, 69_000, 345_000 ],
      2025 => [ 23_500, 7_500, 11_250, 145_000, 70_000, 350_000 ],
      2026 => [ 24_500, 8_000, 11_250, 150_000, 72_000, 360_000 ]
    }.each do |year, amounts|
      AnnualRetirementLimit.find_or_create_by!(tax_year: year) do |limit|
        %i[elective_deferral_limit catch_up_limit enhanced_catch_up_limit
          roth_catch_up_wage_threshold annual_additions_limit compensation_limit].zip(amounts).each do |attribute, value|
          limit.public_send("#{attribute}=", value)
        end
        limit.source_name = "Published IRS #{year} retirement limits (test fixture)"
        limit.source_url = "https://www.irs.gov/retirement-plans/cola-increases-for-dollar-limitations-on-benefits-and-contributions"
      end
    end
  end
end
