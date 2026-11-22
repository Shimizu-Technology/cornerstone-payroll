# frozen_string_literal: true

module ClientOperatingProfiles
  # Read-only parity check comparing each live company's persisted current
  # operating profile against legacy configuration plus intentional audited edits.
  # Makes zero database writes and exposes only company_id, company_name, and
  # field names (never personal data values).
  class ParityChecker
    Difference = Data.define(:company_id, :company_name, :field)
    Result = Data.define(:checked_count, :skipped_test_workspace_count, :differences) do
      def passed?
        differences.empty?
      end
    end

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

        legacy = LegacyProfileBuilder.build(company, active_aire_company_ids: active_aire_company_ids)
        differences.concat(compare_company(company, persisted, legacy))
      end

      Result.new(
        checked_count: checked_count,
        skipped_test_workspace_count: skipped_test_workspace_count,
        differences: differences
      )
    end

    private

    attr_reader :companies, :as_of

    def compare_company(company, persisted, legacy)
      expected = OperatingProfileCatalog.values_for(legacy).merge(audited_overrides(company, persisted))
      OperatingProfileCatalog.values_for(persisted).filter_map do |key, value|
        next if value == expected.fetch(key)

        Difference.new(company_id: company.id, company_name: company.name, field: key)
      end
    end

    def audited_overrides(company, persisted)
      return {} if persisted.version == 1

      versions = company.client_operating_profiles.where(version: 2..persisted.version).select(:id)
      AuditLog.where(
        company_id: company.id,
        action: UpdateService::AUDIT_ACTION,
        record_type: ClientOperatingProfile.name,
        record_id: versions
      ).order(:id).pluck(:metadata).each_with_object({}) do |metadata, values|
        values.merge!(metadata.fetch("after_values"))
      end
    end
  end
end
