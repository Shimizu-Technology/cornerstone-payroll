# frozen_string_literal: true

module YearEnd
  # Deliberately independent of preparation counts, ready stamps and next_step.
  class FilingProgress
    # form_1099_due: false when no payee gets a 1099, so there is nothing to
    # file unless a submission was already recorded.
    def initialize(company:, year:, decisions: nil, records: nil, downloads: nil, form_1099_due: true)
      @company, @year = company, year
      @decisions, @records, @downloads, @form_1099_due = decisions, records, downloads, form_1099_due
    end

    def self.due_date(year)
      date = Date.new(year + 1, 1, 31)
      date += 1 until date.on_weekday?
      date
    end

    def call
      return [] if @year < Checklist::FIRST_TAX_YEAR
      decisions = @decisions || PayrollFilingResponsibility.where(company_id: @company.id, tax_year: @year, quarter: nil, responsible_party: "cornerstone").pluck(:filing_type)
      return [] if @company.practice_copy?

      records = (@records || PayrollFilingRecord.where(company_id: @company.id, tax_year: @year, quarter: nil)).index_by { |r| [ r.filing_type, r.agency ] }
      identities = []
      identities += [ [ "w2_gu_w3_ss", "ssa", "W-2: SSA" ], [ "w2_gu_w3_ss", "drt", "W-2: DRT" ] ] if decisions.include?("w2_gu")
      identities << [ "form_1099_nec", "drt", "1099: DRT" ] if decisions.include?("form_1099") && (@form_1099_due || records.key?([ "form_1099_nec", "drt" ]))
      identities.map do |type, agency, label|
        record = records[[ type, agency ]]
        download = record ? nil : (@downloads ? @downloads[type] : AnnualFilingDownloads.new(company: @company, year: @year, filing_type: type).logs.first)
        { filing_type: type, agency: agency, label: label, status: record&.status || "not_filed",
          submitted_at: record&.submitted_at&.iso8601, resolved_at: record&.resolved_at&.iso8601,
          confirmation_number: record&.confirmation_number, downloaded_at: download&.created_at&.iso8601,
          due_date: self.class.due_date(@year).iso8601 }
      end
    end
  end
end
