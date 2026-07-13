# frozen_string_literal: true

namespace :payroll_liabilities do
  desc "Preview or explicitly backfill immutable liability postings for legacy committed payroll"
  task backfill: :environment do
    company_id = ENV["COMPANY_ID"].presence
    abort "COMPANY_ID is required" unless company_id

    company = Company.find(company_id)
    through_date = ENV["THROUGH_DATE"].present? ? Date.iso8601(ENV.fetch("THROUGH_DATE")) : Date.current
    service = PayrollLiabilityBackfillService.new(company: company, through_date: through_date)
    preview = service.preview

    puts JSON.pretty_generate(preview)

    unless ENV["CONFIRM"] == "BACKFILL"
      puts "Preview only. Re-run with CONFIRM=BACKFILL after validating the period IDs and backup."
      next
    end

    result = service.call(confirm: true)
    puts JSON.pretty_generate(result)
    abort "Backfill completed with errors" if result[:errors].any?
  rescue Date::Error
    abort "THROUGH_DATE must be a valid YYYY-MM-DD date"
  end
end
