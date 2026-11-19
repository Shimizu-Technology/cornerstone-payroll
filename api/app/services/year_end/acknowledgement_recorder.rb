# frozen_string_literal: true

module YearEnd
  # Records a reviewer's "reviewed" decision on one judgment warning. The
  # request must name the digest the reviewer saw; if the data changed since,
  # the review is refused so nobody signs off on numbers they did not see.
  class AcknowledgementRecorder
    class StaleWarning < StandardError; end

    def initialize(company:, actor:, tax_year:, warning_code:, warning_digest:, note:)
      @company = company
      @actor = actor
      @tax_year = Integer(tax_year)
      @warning_code = warning_code.to_s
      @warning_digest = warning_digest.to_s
      @note = note.to_s.strip
    end

    def call
      PayrollFilingResponsibilityPolicy.authorize_record!(actor: actor, company: company)
      definition = JudgmentWarnings::DEFINITIONS[warning_code]
      raise ArgumentError, "Unknown warning" unless definition
      raise ArgumentError, "This warning must be fixed, not acknowledged" unless definition[:kind] == "acknowledge"
      raise ArgumentError, "Say what you reviewed" if note.blank?

      YearEndAcknowledgement.transaction do
        company.lock!
        @actor = User.lock.find_by(id: actor&.id)
        PayrollFilingResponsibilityPolicy.authorize_record!(actor: actor, company: company)
        current_digest = current_digests[warning_code]
        raise StaleWarning, "This warning no longer applies. Reload the checklist." unless current_digest
        raise StaleWarning, "The data behind this warning changed. Reload the checklist and review it again." unless current_digest == warning_digest

        record = company.year_end_acknowledgements.find_or_initialize_by(tax_year: tax_year, warning_code: warning_code)
        before = record.persisted? ? record.payload : nil
        record.assign_attributes(
          warning_digest: warning_digest,
          note: note,
          acknowledged_by: actor,
          acknowledged_by_name: actor.name,
          acknowledged_by_email: actor.email,
          acknowledged_by_role: actor.role,
          acknowledged_at: Time.current
        )
        record.save!

        AuditLog.record!(
          user: actor,
          organization_id: company.organization_id,
          company_id: company.id,
          action: "year_end_acknowledgements#recorded",
          record_type: "year_end_acknowledgements",
          record_id: record.id,
          subject_name: "#{company.name} #{tax_year} year-end review: #{definition[:title]}",
          metadata: { tax_year: tax_year, warning_code: warning_code, before: before, after: record.payload }
        )
        record
      end
    end

    private

    attr_reader :company, :actor, :tax_year, :warning_code, :warning_digest, :note

    def current_digests
      w2_report = W2GuAggregator.new(company, tax_year).generate
      reconciliation = Reconciliation.new(company: company, year: tax_year, w2_report: w2_report).call
      JudgmentWarnings.new(company: company, year: tax_year, w2_report: w2_report, reconciliation: reconciliation).digests
    end
  end
end
