# frozen_string_literal: true

module ClientOperatingProfiles
  # Read-only parity check comparing each live company's persisted current
  # operating profile against LegacyProfileBuilder.attributes_for.
  # Makes zero database writes and exposes only company_id, company_name, and
  # field names (never personal data values).
  class ParityChecker
    Difference = Data.define(:company_id, :company_name, :field)
    Result = Data.define(:checked_count, :skipped_test_workspace_count, :differences) do
      def passed?
        differences.empty?
      end
    end

    CORE_FIELDS = %i[
      offering
      hours_source
      intake_adapter
      client_portal_enabled
      employee_portal_enabled
    ].freeze

    def self.call(companies: Company.all, on: PayrollBusinessClock.today)
      new(companies: companies, on: on).call
    end

    def initialize(companies: Company.all, on: PayrollBusinessClock.today)
      @companies = companies
      @as_of = on.to_date
    end

    def call
      active_aire_company_ids = TimeTrackingSource.active
        .where(source_type: "aire_services")
        .distinct
        .pluck(:company_id)
        .to_set

      checked_count = 0
      skipped_test_workspace_count = 0
      differences = []

      companies.find_each do |company|
        if company.test_workspace?
          skipped_test_workspace_count += 1
          next
        end

        checked_count += 1
        persisted = ClientOperatingProfile.for_date(company.id, as_of)
        if persisted.nil?
          differences << Difference.new(company_id: company.id, company_name: company.name, field: "profile")
          next
        end

        expected = LegacyProfileBuilder.attributes_for(company, active_aire_company_ids: active_aire_company_ids)
        differences.concat(compare_company(company, persisted, expected))
      end

      Result.new(
        checked_count: checked_count,
        skipped_test_workspace_count: skipped_test_workspace_count,
        differences: differences
      )
    end

    private

    attr_reader :companies, :as_of

    def compare_company(company, persisted, expected)
      diffs = []

      CORE_FIELDS.each do |field|
        next if persisted.public_send(field) == expected.fetch(field)

        diffs << Difference.new(company_id: company.id, company_name: company.name, field: field.to_s)
      end

      expected_options = expected.fetch(:options)
      OperatingProfileCatalog.entries.each do |entry|
        next unless entry.option?

        actual_value = persisted.option_value(entry.id)
        expected_value = OperatingProfileCatalog.option_value(expected_options, entry.id)
        next if actual_value == expected_value

        diffs << Difference.new(company_id: company.id, company_name: company.name, field: entry.id)
      end

      diffs
    end
  end
end
