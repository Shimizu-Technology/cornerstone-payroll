# frozen_string_literal: true

module YearEnd
  # When a client's full checklist last came out ready. The clients list
  # trusts a Ready status only while nothing the checklist reads has changed
  # since this time (or since the W-2s were marked ready). A missing entry
  # just makes the list ask staff to re-check, never claim Ready.
  module ReadyCheck
    EXPIRES_IN = 30.days

    def self.key(company_id, year)
      "year_end/ready_check/v1/#{company_id}/#{year}"
    end

    def self.record(company_id, year, checked_at)
      Rails.cache.write(key(company_id, year), checked_at.utc.iso8601(6), expires_in: EXPIRES_IN)
    end

    def self.read_many(company_ids, year)
      return {} if company_ids.empty?

      keys = company_ids.index_by { |company_id| key(company_id, year) }
      Rails.cache.read_multi(*keys.keys).each_with_object({}) do |(cache_key, value), result|
        time = Time.iso8601(value.to_s)
        result[keys.fetch(cache_key)] = time
      rescue ArgumentError
        next
      end
    end
  end
end
