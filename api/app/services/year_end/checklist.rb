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
  #   8. print and file: the documents to print, keep or send. Not a sign-off;
  #      it never changes the status, issue count or next step.
  #
  # Every step reports what is wrong and the one action that fixes it. The same
  # blockers gate the W-2GU "mark ready" endpoint from FIRST_TAX_YEAR onward.
  class Checklist
    FIRST_TAX_YEAR = 2026
    STEP_KEYS = %w[filing_decision employer people reconciliation review_warnings prior_provider mark_ready print_and_file].freeze
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
    # The 1099 decision and 1099 payee items never hold up the W-2s.
    FORM_1099_ONLY_CODES = %w[FORM_1099_FILER_NOT_CHOSEN PAYEE_DETAILS_MISSING PAYEES_UNAVAILABLE PAYEE_IDENTITY_UNRESOLVED].freeze

    def call
      # Taken before the steps run, so a change made while they run leaves
      # the list asking for a re-check.
      revision = InputRevision.for(company.id, year)[company.id]
      steps = build_steps
      status = overall_status(steps)
      # Lets the clients list keep showing Ready until any input changes, and
      # stops it showing Ready once a run finds something.
      status == "ready" ? ReadyCheck.record(company.id, year, revision) : ReadyCheck.clear(company.id, year)
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
        steps: steps + [ print_and_file_step ]
      }
    rescue StandardError
      ReadyCheck.clear(company.id, year)
      raise
    end

    # Blockers the W-2GU "mark ready" action enforces. Preflight still owns
    # employee SSN/address, and the 1099 decision and payee details never
    # hold up the W-2s.
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
      # Employer and people checks run as soon as one recorded decision has
      # Cornerstone filing, so the W-2s never wait on the 1099 decision.
      @steps_before_ready ||= begin
        evaluable = files_any? || decisions_recorded?
        [
          filing_decision_step,
          evaluable ? employer_step : waiting_step("employer", "Employer details"),
          evaluable ? people_step : waiting_step("people", "Employees and payees"),
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
        .reject { |issue| issue[:code].in?(FORM_1099_ONLY_CODES) }
    end

    # The W-2 checks depend only on the W-2 decision.
    def w2_step(key, title)
      return waiting_step(key, title) unless responsibilities["w2_gu"]
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
          one_off_payee_count: one_off_payee_count,
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
      # A 1099-only client files no W-3SS: the phone prints in each 1099's
      # payer box and the contact goes on the Form 1096 transmittal.
      if company.phone.blank?
        issues << issue("EMPLOYER_PHONE_MISSING", files?("w2_gu") ? "Add the employer phone number for the W-3SS contact." : "Add the employer phone number. It prints in the payer box on each 1099.", field: "phone")
      end
      if company.email.blank?
        issues << issue("EMPLOYER_EMAIL_MISSING", files?("w2_gu") ? "Add the employer email for the W-3SS contact." : "Add the employer email for the Form 1096 contact.", field: "email")
      end
      if files?("w2_gu") && company.filing_contact_name.blank?
        issues << issue("EMPLOYER_CONTACT_NAME_MISSING", "Add the employer filing contact name.", field: "filing_contact_name")
      end
      forms = [ ("W-2" if files?("w2_gu")), ("1099" if files?("form_1099")) ].compact.join(" and ")

      step(
        "employer", "Employer details", issues,
        summary: issues.empty? ? "EIN, address and contact details are complete." : "These print on every #{forms}.",
        data: {
          name: company.name, ein: company.ein,
          address_line1: company.address_line1, address_line2: company.address_line2,
          city: company.city, state: company.state, zip: company.zip,
          phone: company.phone, email: company.email,
          filing_contact_name: company.filing_contact_name, kind_of_employer: company.kind_of_employer, employment_code: company.employment_code, establishment_number: company.establishment_number
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

    # Payees reached only by printed or paid one-off contractor checks. Counted
    # straight from the checks, so a 1099 setup problem never hides them from
    # the step 1 default.
    def one_off_payee_count
      threshold = InformationReturnThreshold.find_by(form_type: "1099_nec", tax_year: year)&.threshold_amount&.to_d
      OneOffPayees.reportable_groups(OneOffPayees.issued_check_groups([ company.id ], year), threshold).size
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
      payees = files?("form_1099") ? one_off_payees : []
      issues += payees.reject { |payee| payee[:status] == "identified" }.map do |payee|
        issue("PAYEE_IDENTITY_UNRESOLVED", one_off_payee_message(payee), warning_code: payee[:code])
      end
      issues << issue("PAYEES_UNAVAILABLE", @contractor_error) if files?("form_1099") && !contractors_available?

      step(
        "people", "Employees and payees", issues,
        summary: issues.empty? ? "Every employee#{files?('form_1099') ? ' and 1099 payee' : ''} has a filing ID and address." : "Fix each one below. The list clears as you save.",
        data: {
          employees: employees,
          contractors: contractors,
          one_off_payees: payees,
          w2_employee_count: files?("w2_gu") ? w2_employees.size : 0,
          contractor_count: files?("form_1099") && contractors_available? ? reportable_contractors.size : 0,
          contractor_error: @contractor_error
        }
      )
    end

    # A report that cannot be built leaves the 1099 payee check open (a
    # 1099-only PAYEES_UNAVAILABLE issue), never complete.
    def form_1099_rows
      @form_1099_rows ||= begin
        Array(Form1099NecAggregator.new(company, year).generate[:reportable_contractors])
      rescue ActiveRecord::RecordNotFound, ArgumentError => e
        @contractor_error = "1099 payees could not be loaded: #{e.message.delete_suffix('.')}. Fix the #{year} 1099-NEC setup, then reload this page."
        []
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { company_id: company.id, tax_year: year, source: "year_end_checklist" })
        @contractor_error = "1099 payees could not be loaded. Open the #{year} 1099-NEC report to see the problem, then reload this page."
        []
      end
    end

    def reportable_contractors
      @reportable_contractors ||= begin
        ids = form_1099_rows.filter_map { |row| row[:employee_id] }
        Employee.where(company_id: company.id, id: ids).order(:last_name, :first_name, :id).to_a
      end
    end

    # Reportable payees paid only by one-off contractor checks, with no
    # contractor record to hold a TIN or address.
    def one_off_payees
      @one_off_payees ||= OneOffPayees.new(company: company, year: year, rows: form_1099_rows).call
    end

    def one_off_payee_message(payee)
      numbers = payee[:checks].filter_map { |check| check[:check_number] }
      checks = numbers.any? ? "check#{'s' if numbers.length > 1} #{numbers.to_sentence}" : "#{payee[:payment_count]} one-off check#{'s' unless payee[:payment_count] == 1}"
      prefix = payee[:acknowledgement_stale] ? "The checks changed after #{payee[:name]} was identified. " : ""
      "#{prefix}#{payee[:name]} was paid #{ActiveSupport::NumberHelper.number_to_currency(payee[:total_compensation])} by #{checks} " \
        "with no contractor record or TIN. Record who this payee is."
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
        summary: issues.empty? ? "Nothing in these W-2 totals was paid on or before #{through.strftime('%b %-d, %Y')}." : "These wages would be reported twice, once by the prior provider and once here.",
        data: { prior_provider_through: through.iso8601, overlaps: overlaps }
      )
    end

    # W-2 wages count when they are paid. A dated paycheck overlaps when it
    # was paid on or before the prior provider's last pay date, whatever its
    # work period. An opening balance sums wages paid from its period start
    # to its summary date, so it overlaps when any of that span is on or
    # before the date.
    def prior_provider_overlaps(through)
      overlaps = []
      imported = HistoricalPaycheck
        .joins(:historical_import_batch, :historical_pay_period)
        .where(company_id: company.id, pay_date: year_range, historical_import_batches: { status: "locked" })
        .where.not(employee_id: nil)
      opening = imported.where.not(historical_pay_periods: { period_type: "regular" })
        .where(historical_paychecks: { period_start: ..through })
      dated = imported.where(historical_pay_periods: { period_type: "regular" })
        .where(historical_paychecks: { pay_date: ..through })
      { "opening_balances" => opening, "imported_payroll" => dated }.each do |source, scope|
        count = scope.count
        next if count.zero?

        last = scope.maximum("historical_paychecks.pay_date")
        message = if source == "opening_balances"
          first = scope.minimum("historical_paychecks.period_start")
          "Opening balances covering #{format_date(first)}–#{format_date(last)} are in these W-2 totals"
        else
          first = scope.minimum("historical_paychecks.pay_date")
          "Imported paychecks paid #{format_date(first)}–#{format_date(last)} are in these W-2 totals"
        end
        overlaps << {
          source: source, count: count, first_date: first&.iso8601, last_date: last&.iso8601,
          message: "#{message}, but the prior provider files W-2s for wages paid through #{format_date(through)}."
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

    # Earlier steps must be clear before the sign-off; the 1099 decision and
    # payee details do not hold up the W-2s.
    def mark_ready_step(earlier_steps)
      readiness, fingerprint = w2_readiness
      filing = readiness&.review_payload(fingerprint: fingerprint)
      current = readiness&.current?(fingerprint)
      earlier_blockers = earlier_steps.sum { |step| step[:issues].count { |issue| !issue[:code].in?(FORM_1099_ONLY_CODES) } }

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

    def w2_readiness
      @w2_readiness ||= begin
        readiness = W2FilingReadiness.find_by(company_id: company.id, year: year)
        [ readiness, (W2FilingInputsFingerprint.new(company: company, year: year, report: w2_report).call if readiness) ]
      end
    end

    # -- Step 8 ----------------------------------------------------------

    # A list of documents, each with a one-line explanation and a download.
    # Status "available" sits outside the checklist's done/needs-action
    # counting, which ignores this step entirely.
    def print_and_file_step
      key = "print_and_file"
      title = "Print and file"
      return waiting_step(key, title) unless responsibilities["w2_gu"]
      return not_needed_step(key, title, "Cornerstone does not file #{year} W-2s for this client.") unless files?("w2_gu")

      readiness, fingerprint = w2_readiness
      practice = company.test_workspace?
      final = !practice && W2GuOfficialCopies.final?(company: company, year: year, readiness: readiness, fingerprint: fingerprint)
      summary = if practice
        "This is a practice copy, so every document is a draft. Review them, but don't hand them out or file them."
      elsif final
        "The #{year} W-2s are marked ready. Print each document below."
      else
        "Drafts until the W-2s are marked ready in step 7. Review them, but don't hand them out yet."
      end
      {
        key: key, number: STEP_KEYS.index(key) + 1, title: title, status: "available",
        summary: summary,
        issues: [],
        data: { final: final, documents: w2_copy_documents(final) }
      }
    end

    def w2_copy_documents(final)
      unavailable = if !W2GuOfficialCopies.supported_tax_year?(year)
        W2GuOfficialCopies.unsupported_message(year)
      elsif w2_report.nil?
        "The W-2 totals could not be loaded: #{@w2_report_error.to_s.delete_suffix('.')}."
      elsif Array(w2_report[:employees]).empty?
        "No employees have #{year} W-2 wages."
      end
      count = Array(w2_report&.dig(:employees)).length
      employees = "#{count} employee#{'s' unless count == 1}"
      [
        {
          key: "w2_employee_copies", title: "Employee copies (B and C)",
          description: "Print and give to each employee by #{format_date(w2_employee_due_date)}.",
          detail: "#{employees}, one sheet each, by last name: Copy B on top, Copy C below, IRS instructions on the back. " \
                  "Print double-sided, flipping on the long edge. SSNs show only the last four digits.",
          contains_full_ssn: false
        },
        {
          key: "w2_drt_copy_1", title: "Copy 1 for Guam DRT",
          description: "Your record; not mailed when you e-file.",
          detail: "#{employees}, two to a page. Each download is recorded in the activity log.",
          contains_full_ssn: true
        }
      ].map do |document|
        drt = document[:key] == "w2_drt_copy_1"
        # Test and practice workspaces never produce full SSNs.
        reason = unavailable || (drt_unavailable_reason if drt)
        document.merge(
          format: "pdf", draft: !final, available: reason.nil?, unavailable_reason: reason,
          download: { path: "/admin/reports/#{drt ? 'w2_gu_copy_1_drt' : 'w2_gu_employee_copies'}", params: { year: year } }
        )
      end
    end

    # Copy 1 carries full SSNs: never in a test or practice workspace, and
    # only for staff who may sign off the W-2s.
    def drt_unavailable_reason
      if company.test_workspace?
        "Not available in a practice copy — it contains full SSNs."
      elsif !permissions[:can_mark_ready]
        "Needs client-management access (contains full SSNs)."
      end
    end

    # January 31 of the next year, or the next business day after a weekend.
    def w2_employee_due_date
      date = Date.new(year + 1, 1, 31)
      date += 1 until date.on_weekday?
      date
    end

    # -- Helpers ---------------------------------------------------------

    def overall_status(steps)
      return "needs_action" unless decisions_recorded?
      return "not_filing" unless files_any?

      steps.all? { |step| step[:status].in?(%w[done not_needed]) } ? "ready" : "needs_action"
    end

    def permissions
      @permissions ||= begin
        can_review = user.present? && user.payroll_access_allowed? && user.can_access_company?(company.id) &&
          StaffRolePolicy.allowed?(user, :manage_filing_review)
        {
          can_record_decision: can_review,
          can_acknowledge: can_review,
          can_mark_ready: user.present? && StaffRolePolicy.allowed?(user, :manage_client_administration, company: company)
        }
      end
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
