# frozen_string_literal: true

module ClientOperatingProfiles
  # Idempotently backfills version 1 of client_operating_profiles for any live
  # company that does not already have a profile row. Test workspaces are skipped
  # because read fallback covers them until SetupCloner copies source versions.
  class BackfillService
    def self.call(companies: Company.operating)
      new(companies: companies).call
    end

    def initialize(companies: Company.operating)
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
        if backfill_company(company, active_aire_company_ids)
          created += 1
        else
          skipped += 1
        end
      end

      { created: created, skipped: skipped }
    end

    private

    attr_reader :companies

    def backfill_company(company, active_aire_company_ids)
      company.with_lock(requires_new: true) do
        next if company.practice_copy? || company.client_operating_profiles.exists?

        ClientOperatingProfile.create!(
          LegacyProfileBuilder.attributes_for(company, active_aire_company_ids: active_aire_company_ids)
        )
      end
    end
  end
end
