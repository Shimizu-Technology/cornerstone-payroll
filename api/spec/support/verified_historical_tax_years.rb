# frozen_string_literal: true

# Explicit synthetic setup for older finalization tests that previously supplied
# calculated dollar amounts without configuring the corresponding tax year.
module VerifiedHistoricalTaxYears
  def ensure_verified_test_tax_years(*years)
    years.filter_map do |year|
      raise "This fixture is only for grandfathered tax years" if year > 2026
      next if AnnualTaxConfig.for_year(year) || TaxTable.for_year(year).exists?

      create(:tax_table, tax_year: year, verification_status: "verified")
    end
  end
end

RSpec.configure { |config| config.include VerifiedHistoricalTaxYears }
