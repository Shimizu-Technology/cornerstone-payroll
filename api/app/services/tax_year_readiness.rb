# frozen_string_literal: true

# Read-only, shared by the operator warning and the production release gate.
class TaxYearReadiness
  def initialize(today: Date.current, pay_dates: [])
    @today = today
    @pay_dates = pay_dates
  end

  def as_json(*)
    years = ([ @today.year, (@today + 60.days).year ] + @pay_dates.compact.map(&:year)).uniq.sort
    verified_years = AnnualTaxConfig.where(verification_status: "verified").pluck(:tax_year)
    legacy_years = TaxTable.where(verification_status: "verified").where("tax_year <= 2026").distinct.pluck(:tax_year)
    draft_years = AnnualTaxConfig.where(verification_status: "draft").pluck(:tax_year)
    verified_years |= legacy_years - draft_years
    {
      verified_years: verified_years.sort,
      warnings: (years - verified_years).map do |year|
        { tax_year: year, message: AnnualTaxConfig.unverified_message(year) }
      end
    }
  end
end
