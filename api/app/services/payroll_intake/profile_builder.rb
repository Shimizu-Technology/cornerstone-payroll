# frozen_string_literal: true

module PayrollIntake
  # Builds the read-only intake profile payload for a company from the
  # descriptor registry and effective operating-profile settings.
  class ProfileBuilder
    def initialize(company:, on: nil)
      @company = company
      @as_of = (on || PayrollBusinessClock.today).to_date
    end

    def call
      features = CompanyFeatures.for(@company, on: @as_of)
      adapters = PayrollIntake::Registry.for_company(@company).map do |descriptor|
        descriptor.serialize(required_sources: @company.payroll_intake_required_sources(descriptor.key))
      end

      {
        "company_id" => @company.id,
        "as_of" => @as_of.iso8601,
        "hours_source" => features.hours_source,
        "intake_adapter" => features.intake_adapter,
        "settings" => {
          "tips_default" => features.tips_default,
          "overtime_mode" => features.overtime_mode,
          "workweek_alignment" => features.workweek_alignment
        },
        "adapters" => adapters
      }
    end
  end
end
