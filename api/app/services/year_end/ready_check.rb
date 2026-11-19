# frozen_string_literal: true

module YearEnd
  # The input revision at which a client's W-2 sign-off last checked out:
  # the full checklist came out ready, or mark ready passed the checklist
  # gate. The clients list shows Ready only while the current revision is
  # the same. A checklist run that finds blockers, or fails, clears it, and
  # a missing entry just makes the list ask staff to re-check, never claim
  # Ready.
  module ReadyCheck
    # Bound to the revision, so the entry can never vouch for changed inputs;
    # the expiry only keeps the cache small after the filing season.
    EXPIRES_IN = 180.days

    def self.key(company_id, year)
      "year_end/ready_check/v2/#{company_id}/#{year}"
    end

    def self.record(company_id, year, revision)
      return clear(company_id, year) if revision.blank?

      Rails.cache.write(key(company_id, year), revision, expires_in: EXPIRES_IN)
    end

    def self.clear(company_id, year)
      Rails.cache.delete(key(company_id, year))
    end

    def self.read_many(company_ids, year)
      return {} if company_ids.empty?

      keys = company_ids.index_by { |company_id| key(company_id, year) }
      Rails.cache.read_multi(*keys.keys).to_h { |cache_key, revision| [ keys.fetch(cache_key), revision.to_s ] }
    end
  end
end
