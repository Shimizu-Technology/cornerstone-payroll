# frozen_string_literal: true

# One client per job: a failed client never prevents another client's check.
class YearEndEfileCheckJob < ApplicationJob
  queue_as :default

  def perform(company_id, year, revision)
    return unless year == 2026
    return unless YearEnd::InputRevision.for(company_id, year)[company_id] == revision
    return if YearEnd::EfileCheck.read_many([ company_id ], year).dig(company_id, :revision) == revision

    company = Company.find_by(id: company_id)
    YearEnd::Checklist.new(company: company, year: year).call if company && !company.test_workspace?
  rescue StandardError => error
    # Exception messages can contain private filing data. Log identifiers only.
    Rails.logger.error("Year-end e-file check company_id=#{company_id} year=#{year} error_class=#{error.class.name}")
  ensure
    Rails.cache.delete(YearEnd::EfileCheck.pending_key(company_id, year, revision))
  end
end
