# frozen_string_literal: true

module ClientOperatingProfiles
  # Idempotently backfills version 1 of client_operating_profiles for any live
  # company that does not already have a profile row. Test workspaces are skipped
  # because read fallback covers them until SetupCloner copies source versions.
  class BackfillService
    def self.call(companies: Company.live_payroll)
      new(companies: companies).call
    end

    def initialize(companies: Company.live_payroll)
      @companies = companies
    end

    def call
      active_aire_company_ids = TimeTrackingSource.active
        .where(source_type: "aire_services")
        .distinct
        .pluck(:company_id)
        .to_set

      created = 0
      skipped = 0

      companies.find_each do |company|
        if company.test_workspace? || ClientOperatingProfile.exists?(company_id: company.id)
          skipped += 1
          next
        end

        ClientOperatingProfile.create!(
          LegacyProfileBuilder.attributes_for(company, active_aire_company_ids: active_aire_company_ids)
        )
        created += 1
      end

      { created: created, skipped: skipped }
    end

    private

    attr_reader :companies
  end
end
