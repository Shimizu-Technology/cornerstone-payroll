# frozen_string_literal: true

namespace :payroll_history_review do
  desc "Count detected payroll history items (COMPANY_ID and TAX_YEAR required; APPLY=1 persists)"
  task detect: :environment do
    company_id = Integer(ENV.fetch("COMPANY_ID"), 10)
    year = Integer(ENV.fetch("TAX_YEAR"), 10)
    abort "Choose a valid tax year" unless year.between?(1900, Date.current.year + 1)

    counts = PayrollHistoryReview::Detector.new(company: Company.find(company_id), tax_year: year)
      .call(apply: ENV["APPLY"] == "1").fetch(:counts)
    puts %i[new reopened open resolved proven].to_h { |status| [ status, counts[status] ] }.to_json
  end
end
