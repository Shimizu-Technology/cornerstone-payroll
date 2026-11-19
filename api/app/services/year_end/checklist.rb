# frozen_string_literal: true

module YearEnd
  # One client's year-end checklist, in the order staff work it:
  #
  #   1. who files the year's W-2GUs and 1099s (required before anything else)
  #   2. employer details the forms print
  #   3. employees (and 1099 payees) missing an SSN/TIN or address
  #   4. W-2GU totals reconciled to the 941 quarters and W-1s
  #   5. judgment warnings: fixed, or acknowledged in the audit log
  #   6. prior-provider overlap
  #   7. mark W-2GUs ready (the existing fingerprint-bound attestation)
  #
  # Every step reports what is wrong and the one action that fixes it. The same
  # blockers gate the W-2GU "mark ready" endpoint from FIRST_TAX_YEAR onward.
  class Checklist
    FIRST_TAX_YEAR = 2026
    STEP_KEYS = %w[filing_decision employer people reconciliation review_warnings prior_provider mark_ready].freeze
    PARTY_LABELS = {
      "cornerstone" => "Cornerstone files",
      "client" => "The client files",
      "external_provider" => "Another payroll provider files",
      "no_filing" => "No forms this year"
    }.freeze

    def self.applies_to?(year)
      Integer(year) >= FIRST_TAX_YEAR
    end

    def initialize(company:, year:, user: nil)
      @company = company
      @year = Integer(year)
      @user = user
    end

    # The clients list counts the same "things to fix": each decision, employer
    # and employee item once, and the W-2 sign-off group (reconciliation,
    # warnings, overlap, mark ready) as one item until it is done.
    SIGN_OFF_STEPS = %w[reconciliation review_warnings prior_provider mark_ready].freeze
    # 1099 payee items never hold up the W-2s.
    PAYEE_ONLY_CODES = %w[PAYEE_DETAILS_MISSING PAYEES_UNAVAILABLE PAYEE_IDENTITY_UNRESOLVED].freeze

    def call
      started_at = Time.current
      steps = build_steps
      status = overall_status(steps)
      # Lets the clients list keep showing Ready until any input changes.
      ReadyCheck.record(company.id, year, started_at) if status == "ready"
      issue_count = steps.reject { |step| step[:key].in?(SIGN_OFF_STEPS) }.sum { |step| step[:issues].length } +
        (steps.any? { |step| step[:key].in?(SIGN_OFF_STEPS) && step[:status] == "action_needed" } ? 1 : 0)
      next_step = steps.find { |step| step[:status] == "action_needed" }

      {
        company: {
          id: company.id,
          name: company.name,
          active: company.active?,
          test_workspace: company.test_workspace?
        },
        tax_year: year,
        status: status,
        issue_count: issue_count,
        next_step: next_step&.fetch(:key),
        files_w2: files?("w2_gu"),
        files_1099: files?("form_1099"),
        permissions: permissions,
        steps: steps
      }
    end

    # Blockers the W-2GU "mark ready" action enforces. Preflight still owns
    # employee SSN/address, and 1099 payee details never hold up the W-2s.
    def w2_mark_ready_blockers
      w2_blockers_from(steps_before_ready)
    end

    private

    attr_reader :company, :year, :user

    def year_range
      Date.new(year, 1, 1)..Date.new(year, 12, 31)
    end

    def build_steps
      @build_steps ||= steps_before_ready + [ w2_step("mark_ready", "Mark W-2s ready") { mark_ready_step(steps_before_ready) } ]
    end

    def steps_before_ready
      @steps_before_ready ||= begin
        decided = decisions_recorded?
        [
          filing_decision_step,
          decided ? employer_step : waiting_step("employer", "Employer details"),
          decided ? people_step : waiting_step("people", "Employees and payees"),
          w2_step("reconciliation", "Reconcile W-2s to the 941s and W-1s") { reconciliation_step },
          w2_step("review_warnings", "Review warnings") { review_warnings_step },
          w2_step("prior_provider", "Prior provider overlap") { prior_provider_step }
        ]
      end
    end

    def w2_blockers_from(steps)
      steps
        .select { |step| step[:key].in?(%w[filing_decision employer reconciliation review_warnings prior_provider]) }
        .flat_map { |step| step[:issues] }
    end

    def w2_step(key, title)
      return waiting_step(key, title) unless decisions_recorded?
      return not_needed_step(key, title, "Cornerstone does not file #{year} W-2s for this client.") unless files?("w2_gu")

      yield
    end

    # -- Step 1 ----------------------------------------------------------

    def responsibilities
      @responsibilities ||= company.payroll_filing_responsibilities
        .where(tax_year: year, quarter: nil, filing_type: PayrollFilingResponsibility::YEAR_END_FILING_TYPES)
        .index_by(&:filing_type)
    end

    def decisions_recorded?
      PayrollFilingResponsibility::YEAR_END_FILING_TYPES.all? { |type| responsibilities[type] }
    end

    def files?(filing_type)
      responsibilities[filing_type]&.responsible_party == "cornerstone"
    end

    def filing_decision_step
      issues = []
      issues << issue("W2_FILER_NOT_CHOSEN", "Choose who files #{year} W-2s.") unless responsibilities["w2_gu"]
      issues << issue("FORM_1099_FILER_NOT_CHOSEN", "Choose who files #{year} 1099s.") unless responsibilities["form_1099"]

      step(
        "filing_decision", "Who files #{year} forms", issues,
        summary: issues.empty? ? decision_summary : "Answer this first. The rest of the checklist depends on it.",
        data: {
          w2: decision_payload(responsibilities["w2_gu"]),
          form_1099: decision_payload(responsibilities["form_1099"]),
          w2_employee_count: w2_employees.size,
          contractor_count: contractor_payee_ids.size,
          has_imported_history: locked_history?
        }
      )
    end

    def decision_summary
      w2 = PARTY_LABELS.fetch(responsibilities["w2_gu"].responsible_party)
      form_1099 = PARTY_LABELS.fetch(responsibilities["form_1099"].responsible_party)
      "W-2s: #{w2}. 1099s: #{form_1099}."
    end

    def decision_payload(record)
      return unless record

      record.decision_payload.merge(label: PARTY_LABELS.fetch(record.responsible_party))
    end

    # -- Step 2 ----------------------------------------------------------

    def employer_step
      return not_needed_step("employer", "Employer details", "Cornerstone files no #{year} forms for this client.") unless files_any?

      issues = []
      issues << issue("EMPLOYER_EIN_MISSING", "Add the employer's EIN.", field: "ein") if company.ein.blank?
      if [ company.address_line1, company.city, company.state, company.zip ].any?(&:blank?)
        issues << issue("EMPLOYER_ADDRESS_INCOMPLETE", "Complete the employer address (street, city, state and ZIP).", field: "address")
      end
      issues << issue("EMPLOYER_PHONE_MISSING", "Add the employer phone number for the W-3SS contact.", field: "phone") if company.phone.blank?
      issues << issue("EMPLOYER_EMAIL_MISSING", "Add the employer email for the W-3SS contact.", field: "email") if company.email.blank?

      step(
        "employer", "Employer details", issues,
        summary: issues.empty? ? "EIN, address and contact details are complete." : "These print on every W-2 and 1099.",
        data: {
          name: company.name, ein: company.ein,
          address_line1: company.address_line1, address_line2: company.address_line2,
          city: company.city, state: company.state, zip: company.zip,
          phone: company.phone, email: company.email
        }
      )
    end

    def files_any?
      files?("w2_gu") || files?("form_1099")
    end

    # -- Step 3 ----------------------------------------------------------

    def w2_employees
      @w2_employees ||= W2GuFilingPopulation.employees(company: company, year: year).to_a
    end

    def contractor_payee_ids
      @contractor_payee_ids ||= PayrollItem
        .joins(:pay_period)
        .where(company_id: company.id, employment_type: "contractor")
        .financially_reportable
        .where(pay_periods: { id: PayPeriod.reportable_committed.where(company_id: company.id, pay_date: year_range).select(:id) })
        .distinct.pluck(:employee_id)
    end

    def people_step
      return not_needed_step("people", "Employees and payees", "Cornerstone files no #{year} forms for this client.") unless files_any?

      employees = files?("w2_gu") ? w2_employees.filter_map { |employee| person_row(employee, w2: true) } : []
      contractors = files?("form_1099") ? reportable_contractors.filter_map { |employee| person_row(employee, w2: false) } : []
      issues = employees.map do |row|
        issue("EMPLOYEE_DETAILS_MISSING", "#{row[:name]} is missing #{row[:missing_fields].map { |field| field == 'ssn' ? 'an SSN' : 'an address' }.to_sentence}.",
              employee_id: row[:employee_id])
      end
      issues += contractors.map do |row|
        issue("PAYEE_DETAILS_MISSING", "#{row[:name]} is missing #{row[:missing_fields].map { |field| field == 'ssn' ? 'a TIN' : 'an address' }.to_sentence}.",
              employee_id: row[:employee_id])
      end
      issues << issue("PAYEES_UNAVAILABLE", @contractor_error) if files?("form_1099") && !contractors_available?

      step(
        "people", "Employees and payees", issues,
        summary: issues.empty? ? "Every employee#{files?('form_1099') ? ' and 1099 payee' : ''} has a filing ID and address." : "Fix each one below. The list clears as you save.",
        data: {
          employees: employees,
          contractors: contractors,
          w2_employee_count: files?("w2_gu") ? w2_employees.size : 0,
          contractor_count: files?("form_1099") && contractors_available? ? reportable_contractors.size : 0,
          contractor_error: @contractor_error
        }
      )
    end

    def reportable_contractors
      @reportable_contractors ||= begin
        report = Form1099NecAggregator.new(company, year).generate
        ids = Array(report[:reportable_contractors]).map { |row| row[:employee_id] }
        Employee.where(company_id: company.id, id: ids).order(:last_name, :first_name, :id).to_a
      rescue ActiveRecord::RecordNotFound, ArgumentError => e
        @contractor_error = "1099 payees could not be loaded: #{e.message}"
        []
      end
    end

    def contractors_available?
      reportable_contractors
      @contractor_error.nil?
    end

    def person_row(employee, w2:)
      missing = []
      missing << "ssn" unless w2 ? employee.valid_filing_ssn? : (employee.valid_filing_ssn? || employee.contractor_ein.present?)
      missing << "address" if [ employee.address_line1, employee.city, employee.state, employee.zip ].any?(&:blank?)
      return if missing.empty?

      {
        employee_id: employee.id,
        name: employee.full_name,
        kind: w2 ? "employee" : "contractor",
        missing_fields: missing,
        address_line1: employee.address_line1,
        address_line2: employee.address_line2,
        city: employee.city,
        state: employee.state,
        zip: employee.zip,
        edit_path: "/companies/#{company.id}/employees/#{employee.id}/edit"
      }
    end

    # -- Steps 4 and 5 ---------------------------------------------------

    def w2_report
      return @w2_report if defined?(@w2_report)

      @w2_report = begin
        W2GuAggregator.new(company, year).generate
      rescue ArgumentError => e
        @w2_report_error = e.message
        nil
      end
    end

    def reconciliation
      @reconciliation ||= if w2_report
        Reconciliation.new(company: company, year: year, w2_report: w2_report).call
      else
        Reconciliation.unavailable(@w2_report_error.to_s)
      end
    end

    def reconciliation_step
      issues = reconciliation[:blockers].map do |blocker|
        issue(blocker[:code], blocker[:message], line: blocker[:line], quarter: blocker[:quarter])
      end
      summary = case reconciliation[:status]
      when "match" then "W-2 totals match the 941s and W-1s#{reconciliation.dig(:opening_balances, :present) ? ' after opening balances' : ''}."
      when "unavailable" then "The totals could not be compared yet."
      else "Totals differ by more than a cent. Fix the payroll or return named on each line."
      end
      step("reconciliation", "Reconcile W-2s to the 941s and W-1s", issues, summary: summary, data: reconciliation)
    end

    def judgment_warnings
      @judgment_warnings ||= if w2_report
        JudgmentWarnings.new(company: company, year: year, w2_report: w2_report, reconciliation: reconciliation).call
      else
        []
      end
    end

    def review_warnings_step
      issues = judgment_warnings.filter_map do |warning|
        next if warning[:status] == "reviewed"

        message = if warning[:kind] == "blocker"
          "#{warning[:title]}: fix #{warning[:employees].length} employee#{'s' unless warning[:employees].length == 1}."
        elsif warning[:acknowledgement_stale]
          "#{warning[:title]}: the data changed after it was reviewed. Review it again."
        else
          "#{warning[:title]}: review and record what you confirmed."
        end
        issue(warning[:kind] == "blocker" ? "JUDGMENT_WARNING_BLOCKING" : "JUDGMENT_WARNING_UNREVIEWED", message, warning_code: warning[:code])
      end
      summary = if judgment_warnings.empty? && w2_report.nil?
        "Warnings are checked once the W-2 totals load."
      elsif judgment_warnings.empty?
        "No warnings for this year."
      elsif issues.empty?
        "Every warning is reviewed."
      else
        "Fix each blocker. Review each other warning and say what you confirmed."
      end
      step("review_warnings", "Review warnings", issues, summary: summary, data: { warnings: judgment_warnings })
    end

    # -- Step 6 ----------------------------------------------------------

    def locked_history?
      return @locked_history if defined?(@locked_history)

      @locked_history = company.historical_import_batches
        .joins(:historical_paychecks)
        .where(status: "locked", historical_paychecks: { pay_date: year_range })
        .exists?
    end

    def prior_provider_step
      through = responsibilities["w2_gu"].prior_provider_through
      unless through
        return step("prior_provider", "Prior provider overlap", [],
                    summary: "No prior provider files #{year} W-2s for this client.",
                    data: { prior_provider_through: nil, overlaps: [] })
      end

      overlaps = prior_provider_overlaps(through)
      issues = overlaps.map do |overlap|
        issue("PRIOR_PROVIDER_OVERLAP", overlap[:message], source: overlap[:source])
      end
      step(
        "prior_provider", "Prior provider overlap", issues,
        summary: issues.empty? ? "Nothing in these W-2 totals is dated on or before #{through.strftime('%b %-d, %Y')}." : "These wages would be reported twice, once by the prior provider and once here.",
        data: { prior_provider_through: through.iso8601, overlaps: overlaps }
      )
    end

    def prior_provider_overlaps(through)
      overlaps = []
      imported = HistoricalPaycheck
        .joins(:historical_import_batch, :historical_pay_period)
        .where(company_id: company.id, pay_date: year_range, historical_import_batches: { status: "locked" })
        .where.not(employee_id: nil)
        .where("historical_paychecks.pay_date <= :through OR historical_paychecks.period_start <= :through", through: through)
      opening = imported.where.not(historical_pay_periods: { period_type: "regular" })
      dated = imported.where(historical_pay_periods: { period_type: "regular" })
      { "opening_balances" => opening, "imported_payroll" => dated }.each do |source, scope|
        count = scope.count
        next if count.zero?

        first = scope.minimum("historical_paychecks.period_start") || scope.minimum("historical_paychecks.pay_date")
        last = scope.maximum("historical_paychecks.pay_date")
        label = source == "opening_balances" ? "Opening balances" : "Imported paychecks"
        overlaps << {
          source: source, count: count, first_date: first&.iso8601, last_date: last&.iso8601,
          message: "#{label} covering #{format_date(first)}–#{format_date(last)} are in these W-2 totals, but the prior provider files W-2s for wages paid through #{format_date(through)}."
        }
      end

      # Only payroll that counts in these W-2 totals can overlap: contractor-only
      # or non-reportable pay runs are not W-2 wages.
      native = PayPeriod.where(id: W2PayrollItems.scope(company.id, year)
        .where(pay_periods: { pay_date: Date.new(year, 1, 1)..through }).select("payroll_items.pay_period_id"))
      if native.exists?
        overlaps << {
          source: "cornerstone_payroll", count: native.count,
          first_date: native.minimum(:pay_date)&.iso8601, last_date: native.maximum(:pay_date)&.iso8601,
          message: "Cornerstone payroll paid on #{format_date(native.minimum(:pay_date))} is on or before #{format_date(through)}, the last date the prior provider files for. Check the prior provider's date."
        }
      end
      overlaps
    end

    # -- Step 7 ----------------------------------------------------------

    # Earlier steps must be clear before the sign-off; 1099 payee details do
    # not hold up the W-2s.
    def mark_ready_step(earlier_steps)
      readiness = W2FilingReadiness.find_by(company_id: company.id, year: year)
      fingerprint = W2FilingInputsFingerprint.new(company: company, year: year, report: w2_report).call if readiness
      filing = readiness&.review_payload(fingerprint: fingerprint)
      current = readiness&.current?(fingerprint)
      earlier_blockers = earlier_steps.sum { |step| step[:issues].count { |issue| !issue[:code].in?(PAYEE_ONLY_CODES) } }

      issues = []
      unless current
        message = if filing&.dig(:stale)
          "Payroll or filing details changed after the W-2s were marked ready. Mark them ready again."
        else
          "Mark the #{year} W-2s ready once everything above is done."
        end
        issues << issue("W2_NOT_MARKED_READY", message)
      end

      step(
        "mark_ready", "Mark W-2s ready", issues,
        summary: current ? "Marked ready#{readiness.marked_ready_at ? " on #{readiness.marked_ready_at.in_time_zone('Pacific/Guam').strftime('%b %-d, %Y')}" : ''}." : "This records your sign-off on the current numbers.",
        data: {
          filing: filing,
          can_mark_ready: earlier_blockers.zero?,
          remaining_before_ready: earlier_blockers
        }
      )
    end

    # -- Helpers ---------------------------------------------------------

    def overall_status(steps)
      return "needs_action" unless decisions_recorded?
      return "not_filing" unless files_any?

      steps.all? { |step| step[:status].in?(%w[done not_needed]) } ? "ready" : "needs_action"
    end

    def permissions
      can_review = user.present? && user.payroll_access_allowed? && user.can_access_company?(company.id) &&
        StaffRolePolicy.allowed?(user, :manage_filing_review)
      {
        can_record_decision: can_review,
        can_acknowledge: can_review,
        can_mark_ready: user.present? && StaffRolePolicy.allowed?(user, :manage_client_administration, company: company)
      }
    end

    def step(key, title, issues, summary:, data:)
      {
        key: key,
        number: STEP_KEYS.index(key) + 1,
        title: title,
        status: issues.empty? ? "done" : "action_needed",
        summary: summary,
        issues: issues,
        data: data
      }
    end

    def waiting_step(key, title)
      {
        key: key, number: STEP_KEYS.index(key) + 1, title: title, status: "waiting",
        summary: "Answer step 1 first.", issues: [], data: {}
      }
    end

    def not_needed_step(key, title, summary)
      {
        key: key, number: STEP_KEYS.index(key) + 1, title: title, status: "not_needed",
        summary: summary, issues: [], data: {}
      }
    end

    def issue(code, message, **details)
      { code: code, message: message, **details }
    end

    def format_date(date)
      date&.strftime("%b %-d, %Y")
    end
  end
end
