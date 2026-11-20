# frozen_string_literal: true

module YearEnd
  # Employee preflight results are expensive; reuse only at the exact input revision.
  module EfileCheck
    def self.key(company_id, year)
      "year_end/efile_check/v2/#{company_id}/#{year}"
    end

    # `readiness` is the ready mark's stamp when the check ran. The ready mark
    # is not part of the input revision, so the sign-off flag is reused only
    # while both still match.
    def self.record(company_id, year, revision, issues, sign_off_needed: nil, readiness: nil)
      Rails.cache.write(key(company_id, year), { revision: revision, issues: issues, sign_off_needed: sign_off_needed, readiness: readiness }, expires_in: ReadyCheck::EXPIRES_IN)
    end

    def self.readiness_stamp(readiness)
      return nil unless readiness

      [ readiness.status, readiness.marked_ready_at&.utc&.iso8601(6), readiness.updated_at&.utc&.iso8601(6) ].join("|")
    end

    # A successful mark-ready has just confirmed nothing is outstanding at this
    # revision, so the cached check takes the new ready mark's stamp.
    def self.signed_off(company_id, year, revision, readiness)
      stored = Rails.cache.read(key(company_id, year))
      return unless stored && stored[:revision] == revision

      record(company_id, year, revision, stored[:issues], sign_off_needed: false, readiness: readiness_stamp(readiness))
    end

    def self.current_readiness_stamp(company_id, year)
      readiness_stamp(W2FilingReadiness.find_by(company_id: company_id, year: year))
    end

    # Deduplicates repeated list loads. Two first loads at the same moment can
    # both enqueue; that only costs a repeated check. The lease also recovers
    # from a worker disappearing before its ensure runs.
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
