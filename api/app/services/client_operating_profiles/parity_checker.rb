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
      profiles = company.client_operating_profiles.order(:version).to_a
      audits = AuditLog.where(
        company_id: company.id,
        action: UpdateService::AUDIT_ACTION,
        actor_type: "staff_user",
        record_type: ClientOperatingProfile.name,
        record_id: profiles.drop(1).map(&:id)
      ).order(:id).group_by(&:record_id)

      differences = []
      baseline = profiles.first
      values = OperatingProfileCatalog.values_for(baseline)
      overrides = {}
      effective_overrides = {}
      differences << "profile.version" unless baseline.version == 1

      profiles.each_cons(2) do |previous, profile|
        differences << "profile.version" unless profile.version == previous.version + 1
        rows = audits.fetch(profile.id, [])
        differences << "profile.audit.v#{profile.version}" if rows.empty?
        rows.each do |audit|
          changes = audited_changes(profile, audit.metadata, values)
          if changes
            values.merge!(changes)
            overrides.merge!(changes)
          else
            differences << "profile.audit.v#{profile.version}"
          end
        end
        differences.concat(changed_keys(OperatingProfileCatalog.values_for(profile), values))
        effective_overrides = overrides.dup if profile.id == persisted.id
      end

      expected = OperatingProfileCatalog.values_for(legacy).merge(effective_overrides)
      differences.concat(changed_keys(OperatingProfileCatalog.values_for(persisted), expected))
      differences.uniq.map { |field| Difference.new(company_id: company.id, company_name: company.name, field: field) }
    end

    def changed_keys(actual, expected)
      actual.keys.reject { |key| actual.fetch(key) == expected.fetch(key) }
    end

    def audited_changes(profile, metadata, values)
      return unless metadata.is_a?(Hash)
      return unless metadata["version"] == profile.version && metadata["effective_on"] == profile.effective_on.iso8601

      before = metadata["before_values"]
      after = metadata["after_values"]
      fields = metadata["changed_fields"]
      return unless before.is_a?(Hash) && after.is_a?(Hash) && fields.is_a?(Array) && fields.present?
      return unless fields.tally == before.keys.tally && fields.tally == after.keys.tally
      return unless before == values.slice(*fields) && fields.all? { |key| before[key] != after[key] }

      after
    end
  end
end
