# frozen_string_literal: true

module YearEnd
  # Employee preflight results are expensive; reuse only at the exact input revision.
  module EfileCheck
    def self.key(company_id, year)
      "year_end/efile_check/v1/#{company_id}/#{year}"
    end

    def self.record(company_id, year, revision, issues, sign_off_needed: nil)
      Rails.cache.write(key(company_id, year), { revision: revision, issues: issues, sign_off_needed: sign_off_needed }, expires_in: ReadyCheck::EXPIRES_IN)
    end

    def self.read_many(company_ids, year)
      keys = company_ids.index_by { |id| key(id, year) }
      return {} if keys.empty?

      Rails.cache.read_multi(*keys.keys).to_h { |key, value| [ keys.fetch(key), value ] }
    end
  end
end
