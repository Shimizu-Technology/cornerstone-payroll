# frozen_string_literal: true

module YearEnd
  # "Mark 1099s ready": records a reviewer's sign-off on exactly the 1099
  # inputs they reviewed (Form1099InputsFingerprint). The caller holds the
  # company lock, which payee resolution and the 1099 downloads also take.
  #
  # Refused when Cornerstone doesn't file the client's 1099s, when a 1099
  # item in the checklist is open (W-2 items never hold it up), when no payee
  # gets a 1099, when a copy wouldn't print or the e-file would refuse a
  # payer or payee record, or when the inputs differ from the fingerprint
  # the reviewer saw or change while they are checked.
  class Form1099MarkReady
    class Refused < StandardError
      attr_reader :status, :details

      def initialize(message, status: :unprocessable_entity, details: {})
        @status = status
        @details = details
        super(message)
      end
    end

    def initialize(company:, actor:, tax_year:, inputs_fingerprint:, notes: nil)
      @company = company
      @actor = actor
      @tax_year = Integer(tax_year)
      @inputs_fingerprint = inputs_fingerprint.to_s
      @notes = notes.to_s.strip.presence
    end

    def call
      checklist = Checklist.new(company: company, year: tax_year, user: actor)
      state = checklist.form_1099_state
      raise Refused, "Cornerstone does not file #{tax_year} 1099s for this client. Change who files in step 1 first." unless state.cornerstone_files
      raise Refused, "The 1099 payees could not be loaded: #{state.report_error.to_s.delete_suffix('.')}." unless state.report

      blockers = checklist.form_1099_mark_ready_blockers
      if blockers.any?
        raise Refused.new("Finish the 1099 items in the #{tax_year} year-end checklist before marking the 1099s ready.", details: { year_end_blockers: blockers })
      end
      raise Refused, "No payee reached the #{tax_year} 1099 threshold, so there are no 1099s to mark ready." if state.payee_rows.empty?
      if inputs_fingerprint.blank? || inputs_fingerprint != state.fingerprint
        raise Refused.new("The 1099 payees, amounts or payer details changed since this page loaded. Review them again, then mark ready.", status: :conflict)
      end
      if Form1099NecOfficialCopies.supported_tax_year?(tax_year)
        # The copies and the e-file both have to come out of what is signed
        # off: the e-file's own payer and payee checks (for example its
        # 40-character limit on the street and suite joined with a space).
        problems = Form1099NecOfficialCopies.new(company: company, report: state.report, kind: "payer", draft: true).problems
        pub1220_problems = Form1099Pub1220Generator.new(company: company, year: tax_year, submitter: nil, draft: true, report: state.report).client_problems
        if company.demo? && Efw2Formatting.reserved_ein_prefix?(company.ein)
          pub1220_problems = pub1220_problems.reject { |message| message == "Payer: valid EIN required" }
        end
        problems += pub1220_problems
        problems.uniq!
        raise Refused.new("These 1099s wouldn't print or e-file. Fix each item, then mark them ready.", details: { problems: problems }) if problems.any?
      end

      # The stored fingerprint must describe what was just checked. A write
      # that skipped the company lock while the checks ran changes it.
      # Read uncached: the request's query cache would replay the reads above.
      current = ActiveRecord::Base.uncached { Form1099InputsFingerprint.new(company: company, year: tax_year).call }
      unless current == state.fingerprint
        raise Refused.new("The 1099 inputs changed while they were being checked. Review them again, then mark ready.", status: :conflict)
      end

      record!(state)
    end

    private

    attr_reader :company, :actor, :tax_year, :inputs_fingerprint, :notes

    def record!(state)
      readiness = Form1099FilingReadiness.find_or_initialize_by(company_id: company.id, tax_year: tax_year)
      return readiness if readiness.current?(state.fingerprint)

      previous = readiness.ready_fingerprint
      total = state.payee_rows.sum(0.to_d) { |row| row[:total_compensation].to_d }.round(2)
      readiness.assign_attributes(
        ready_fingerprint: state.fingerprint,
        marked_ready_at: Time.current,
        marked_ready_by: actor,
        marked_ready_by_name: actor.name.presence || actor.email,
        notes: notes,
        payee_count: state.payee_rows.length,
        total_compensation: total
      )
      readiness.attestation_history += [ {
        "source_fingerprint" => state.fingerprint, "marked_ready_at" => readiness.marked_ready_at.iso8601,
        "marked_ready_by_id" => actor.id, "payee_count" => readiness.payee_count,
        "total_compensation" => OneOffPayees.money(total), "notes" => notes
      } ]
      readiness.save!
      AuditLog.record!(
        user: actor, organization_id: company.organization_id, company_id: company.id,
        action: "year_end#form_1099_mark_ready", record_type: "form_1099_filing_readinesses", record_id: readiness.id,
        subject_name: "#{company.name} #{tax_year} 1099s marked ready",
        metadata: {
          tax_year: tax_year, inputs_fingerprint: state.fingerprint, previous_fingerprint: previous,
          payee_count: readiness.payee_count, total_compensation: OneOffPayees.money(total), notes: notes
        }
      )
      readiness
    end
  end
end
