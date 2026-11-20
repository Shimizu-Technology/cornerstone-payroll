# frozen_string_literal: true

module YearEnd
  # Employee preflight results are expensive; reuse only at the exact input revision.
  module EfileCheck
    def self.key(company_id, year)
      "year_end/efile_check/v2/#{company_id}/#{year}"
    end

    def self.record(company_id, year, revision, issues, sign_off_needed: nil)
      Rails.cache.write(key(company_id, year), { revision: revision, issues: issues, sign_off_needed: sign_off_needed }, expires_in: ReadyCheck::EXPIRES_IN)
    end

    # Atomic across web processes with the production Solid Cache store. The
    # lease also recovers from a worker disappearing before its ensure runs.
    def self.pending_key(company_id, year, revision)
      "#{key(company_id, year)}/pending/#{revision}"
    end

    def self.enqueue(company_id, year, revision)
      lease = pending_key(company_id, year, revision)
      return unless Rails.cache.write(lease, true, unless_exist: true, expires_in: 1.hour)

      job = YearEndEfileCheckJob.perform_later(company_id, year, revision)
      Rails.cache.delete(lease) unless job
    rescue StandardError => error
      Rails.cache.delete(lease)
      Rails.logger.error("Year-end e-file enqueue company_id=#{company_id} year=#{year} error_class=#{error.class.name}")
    end

    def self.read_many(company_ids, year)
      keys = company_ids.index_by { |id| key(id, year) }
      return {} if keys.empty?

      Rails.cache.read_multi(*keys.keys).to_h { |key, value| [ keys.fetch(key), value ] }
    end
  end
end
