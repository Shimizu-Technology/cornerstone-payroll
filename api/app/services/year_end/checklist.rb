# frozen_string_literal: true

module YearEnd
  # One client's year-end checklist, in the order staff work it:
  #
  #   1. who files the year's W-2GUs and 1099s (required before anything else)
  #   2. employer details the forms print
  #   3. employees (and 1099 payees) missing an SSN/TIN or address, and
  #      one-off 1099 payees to link to a contractor or mark as owing none
  #   -  mark 1099s ready: only when Cornerstone files the client's 1099s. A
  #      fingerprint-bound sign-off on what prints on the 1099-NECs.
  #   4. W-2GU totals reconciled to the 941 quarters and W-1s
  #   5. judgment warnings: fixed, or acknowledged in the audit log
  #   6. prior-provider overlap
  #   7. mark W-2GUs ready (the existing fingerprint-bound attestation)
  #   8. print and file: the documents to print, keep or send. Not a sign-off;
  #      it never changes the status, issue count or next step.
  #
  # Steps are numbered in the order shown, so the W-2 steps move down one
  # when the 1099 step is there. Every step reports what is wrong and the one
  # action that fixes it. The same blockers gate the W-2GU "mark ready"
  # endpoint from FIRST_TAX_YEAR onward; the 1099 ones gate "mark 1099s
  # ready". Neither sign-off waits on the other.
  class Checklist
    FIRST_TAX_YEAR = 2026
    STEP_KEYS = %w[filing_decision employer people form_1099_ready reconciliation review_warnings prior_provider mark_ready print_and_file].freeze
    PARTY_LABELS = {
      "cornerstone" => "Cornerstone files",
      "client" => "The client files",
      "external_provider" => "Another payroll provider files",
      "no_filing" => "No forms this year"
    }.freeze

    def self.applies_to?(year)
      Integer(year) >= FIRST_TAX_YEAR
    end

    # `responsibilities` lets the clients list pass its grouped decisions
    # (filing type => record) instead of loading them again per client.
    def initialize(company:, year:, user: nil, responsibilities: nil)
      @company = company
      @year = Integer(year)
      @user = user
      @responsibilities = responsibilities
    end

    # The clients list counts the same "things to fix": each decision, employer
    # and employee item once, and the W-2 sign-off group (reconciliation,
    # warnings, overlap, mark ready) as one item until it is done.
    SIGN_OFF_STEPS = %w[reconciliation review_warnings prior_provider mark_ready].freeze
    # The 1099 decision, 1099 payee items and the 1099 sign-off never hold up
    # the W-2s.
    FORM_1099_ONLY_CODES = %w[FORM_1099_FILER_NOT_CHOSEN PAYEE_DETAILS_MISSING PAYEE_W9_MISSING PAYEES_UNAVAILABLE
                              PAYEE_IDENTITY_UNRESOLVED PAYEE_DUPLICATE_TIN FORM_1099_NOT_MARKED_READY].freeze
    # Employer items only the W-2 filing needs; they never hold up the 1099s.
    W2_ONLY_EMPLOYER_CODES = %w[EMPLOYER_CONTACT_NAME_MISSING EMPLOYER_EFILE_INVALID].freeze
    # Expected demo preflight notice for fictional 9xx SSNs: shown in the
    # checklist without loosening the official EFW2 validator or blocking sign-off.
    DEMO_EXPECTED_CODES = %w[DEMO_RESERVED_SSN_EXPECTED].freeze
    DEMO_RESERVED_SSN_PATTERN = /\A9\d{2}(?!00)\d{2}(?!0000)\d{4}\z/

    def call
      # Taken before the steps run, so a change made while they run leaves
      # the list asking for a re-check.
      revision = InputRevision.for(company.id, year)[company.id]
      readiness = EfileCheck.current_readiness_stamp(company.id, year)
      steps = build_steps
      EfileCheck.record(company.id, year, revision, efw2_people_issues, sign_off_needed: sign_off_needed?(steps), readiness: readiness) if efile_preflight?
      status = overall_status(steps)
      # Lets the clients list keep showing Ready until any input changes, and
      # stops it showing Ready once a run finds something. The list checks
      # the 1099 items (payees and the 1099 sign-off) live, so only the rest
      # of the checklist has to have checked out.
      only_1099_open = status == "needs_action" && decisions_recorded? && files_any? &&
        steps.all? { |step| step[:issues].all? { |issue| issue[:code].in?(FORM_1099_ONLY_CODES) || issue[:code].in?(DEMO_EXPECTED_CODES) } }
      status == "ready" || only_1099_open ? ReadyCheck.record(company.id, year, revision) : ReadyCheck.clear(company.id, year)
      issue_count = steps.reject { |step| step[:key].in?(SIGN_OFF_STEPS) }.sum { |step| step[:issues].count { |issue| !issue[:code].in?(DEMO_EXPECTED_CODES) } } +
        (sign_off_needed?(steps) ? 1 : 0)
      next_step = steps.find { |step| step[:status] == "action_needed" }
      steps = numbered(steps)
      documents = print_and_file_step(steps)

      {
        company: {
          id: company.id,
          name: company.name,
          demo: company.demo?,
          active: company.active?,
          test_workspace: company.practice_copy?
        },
        tax_year: year,
        status: status,
        issue_count: issue_count,
        next_step: next_step&.fetch(:key),
        files_w2: files?("w2_gu"),
        files_1099: files?("form_1099"),
        permissions: permissions,
        steps: steps + [ documents.merge(number: steps.length + 1) ],
        filing_progress: filing_progress
      }
    rescue StandardError
      ReadyCheck.clear(company.id, year)
      raise
    end

    def filing_progress
      FilingProgress.new(company: company, year: year, form_1099_due: !files?("form_1099") || !no_1099_filings?).call
    rescue StandardError
      Rails.logger.warn("year_end_filing_progress_failed company_id=#{company.id} tax_year=#{year}")
      []
    end

    # Blockers the W-2GU "mark ready" action enforces, including the people
    # step's e-file problems. The 1099 decision and payee details never hold
    # up the W-2s.
    def w2_mark_ready_blockers
      revision = InputRevision.for(company.id, year)[company.id]
      readiness = EfileCheck.current_readiness_stamp(company.id, year)
      blockers = w2_blockers_from(w2_steps_before_ready)
      EfileCheck.record(company.id, year, revision, efw2_people_issues, sign_off_needed: sign_off_needed?(w2_steps_before_ready + [ w2_mark_ready ]), readiness: readiness) if efile_preflight?
      blockers
    end

    # The W-2 sign-off group (reconciliation, warnings, overlap, mark ready)
    # still has something to do. Both e-file cache writers use this one rule.
    def sign_off_needed?(steps)
      steps.any? { |step| step[:key].in?(SIGN_OFF_STEPS) && step[:status] == "action_needed" }
    end

    def efw2_employer_issues
      return [] unless efile_preflight?

      Efw2Formatting.employer_problems(company, structured: true).reject do |problem|
        case problem[:code]
        when :ein_invalid then company.ein.blank?
        when :phone_invalid then company.phone.blank?
        when :email_invalid then company.email.blank?
        when :contact_name_missing then company.filing_contact_name.blank?
        when :address_missing, :address_invalid
          [ company.address_line1, company.city, company.state, company.zip ].any?(&:blank?)
        else false
        end
      end.map do |problem|
        field = if problem[:code] == :ein_invalid
          "ein"
        elsif problem[:code].in?(%i[address_missing address_invalid state_invalid])
          "address"
        end
        issue("EMPLOYER_EFILE_INVALID", problem[:message], field: field)
      end
    end

    def efw2_people_issues
      missing = w2_employees.to_h { |employee| [ employee.id, person_row(employee, w2: true)&.fetch(:missing_fields, []) || [] ] }
      employees_by_id = w2_employees.index_by(&:id)
      demo_reserved_ssn_employee_ids = []
      issues = efw2_problems.filter_map do |problem|
        message = problem[:message]
        next unless problem[:scope] == :employee
        fields = missing.fetch(problem[:employee_id], [])
        next if (fields.include?("ssn") && problem[:code] == :ssn_invalid) || (fields.include?("address") && problem[:code].in?(%i[address_missing address_invalid]))

        if company.demo? && problem[:code] == :ssn_invalid &&
            employees_by_id[problem[:employee_id]]&.ssn_digits.to_s.match?(DEMO_RESERVED_SSN_PATTERN)
          demo_reserved_ssn_employee_ids << problem[:employee_id]
          next
        end

        issue("EMPLOYEE_EFILE_INVALID", message, employee_id: problem[:employee_id])
      end
      if demo_reserved_ssn_employee_ids.any?
        ids = demo_reserved_ssn_employee_ids.uniq
        issues << issue(
          "DEMO_RESERVED_SSN_EXPECTED",
          "Expected demo e-file preflight error: #{ids.length} demo #{'employee'.pluralize(ids.length)} use fictional 9xx SSNs, which the official EFW2 validator rejects.",
          expected_for_demo: true,
          employee_ids: ids
        )
      end
      issues
    end

    # Runs for every operating company (live clients and demos), never practice copies.
    # The official EFW2 validator is never loosened; demo 9xx SSNs are grouped
    # into one labeled expected preflight error above.
    def efile_preflight?
      year == 2026 && files?("w2_gu") && !company.practice_copy?
    end

    def efw2_problems
      return [] unless efile_preflight? && w2_report

      @efw2_problems ||= Efw2W2GuGenerator.new(company: company, year: year, submitter: nil, report: w2_report).structured_problems.reject do |problem|
        problem[:scope] == :submitter
      end
    end

    # What "mark 1099s ready" enforces: the 1099 decision, the employer
    # details a 1099 prints, and every 1099 payee item. W-2 items never hold
    # up the 1099s.
    def form_1099_mark_ready_blockers
      form_1099_blockers_from(base_steps)
    end

    # The 1099 filing state built from this checklist's own 1099-NEC report.
    def form_1099_state
      @form_1099_state ||= begin
        form_1099_rows
        Form1099NecFilingState.new(company: company, year: year, report: @form_1099_report, report_error: @contractor_error).call
      end
    end

    private

    attr_reader :company, :year, :user

    def year_range
      Date.new(year, 1, 1)..Date.new(year, 12, 31)
    end

    def build_steps
      @build_steps ||= steps_before_ready + [ w2_mark_ready ]
    end

    def w2_mark_ready
      @w2_mark_ready ||= w2_step("mark_ready", "Mark W-2s ready") { mark_ready_step(w2_steps_before_ready) }
    end

    # The 1099 sign-off sits after the people step, only when Cornerstone
    # files the client's 1099s.
    def steps_before_ready
      @steps_before_ready ||= base_steps + [ (form_1099_ready_step(base_steps) if files?("form_1099")) ].compact + w2_checks
    end

    # What the W-2 sign-off waits on; never the 1099 sign-off.
    def w2_steps_before_ready
      base_steps + w2_checks
    end

    def w2_checks
      @w2_checks ||= [
        w2_step("reconciliation", "Reconcile W-2s to the 941s and W-1s") { reconciliation_step },
        w2_step("review_warnings", "Review warnings") { review_warnings_step },
        w2_step("prior_provider", "Prior provider overlap") { prior_provider_step }
      ]
    end

    # Employer and people checks run as soon as one recorded decision has
    # Cornerstone filing, so the W-2s never wait on the 1099 decision.
    def base_steps
      @base_steps ||= begin
        evaluable = files_any? || decisions_recorded?
        [
          filing_decision_step,
          evaluable ? employer_step : waiting_step("employer", "Employer details"),
          evaluable ? people_step : waiting_step("people", "Employees and payees")
        ]
      end
    end

    def numbered(steps)
      steps.each_with_index.map { |step, index| step.merge(number: index + 1) }
    end

    def w2_blockers_from(steps)
      steps
        .select { |step| step[:key].in?(%w[filing_decision employer people reconciliation review_warnings prior_provider]) }
        .flat_map { |step| step[:issues] }
        .reject { |issue| issue[:code].in?(FORM_1099_ONLY_CODES) || issue[:code].in?(DEMO_EXPECTED_CODES) }
    end

    def form_1099_blockers_from(steps)
      steps.flat_map do |step|
        case step[:key]
        when "filing_decision" then step[:issues].select { |issue| issue[:code] == "FORM_1099_FILER_NOT_CHOSEN" }
        when "employer" then step[:issues].reject { |issue| issue[:code].in?(W2_ONLY_EMPLOYER_CODES) }
        when "people" then step[:issues].select { |issue| issue[:code].in?(FORM_1099_ONLY_CODES) }
        else []
        end
      end
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
      issues += efw2_employer_issues
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
        .distinct.pluck(:employee_id) | issued_contractor_checks.filter_map(&:payee_employee_id)
    end

    # Printed or paid contractor checks dated in the year, linked or not.
    def issued_contractor_checks
      @issued_contractor_checks ||= OneOffPayees.issued_checks([ company.id ], year)
    end

    # Payees reached only by printed or paid one-off contractor checks that
    # are not linked to a contractor. Counted straight from the checks, so a
    # 1099 setup problem never hides them from the step 1 default.
    def one_off_payee_count
      threshold = InformationReturnThreshold.find_by(form_type: "1099_nec", tax_year: year)&.threshold_amount&.to_d
      OneOffPayees.reportable_groups(OneOffPayees.issued_check_groups([ company.id ], year, checks: issued_contractor_checks), threshold).size
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
      # Each reportable payee's W-9 must be on file before the 1099s are
      # marked ready: staff tick "W-9 on file" on the contractor's record.
      w9_missing = files?("form_1099") ? reportable_contractors.reject(&:w9_on_file?) : []
      issues += w9_missing.map do |employee|
        issue("PAYEE_W9_MISSING", "#{employee.full_name}'s W-9 is not on file. Open the contractor and tick W-9 on file once you have it.",
              employee_id: employee.id)
      end
      issues += efw2_people_issues
      payees = files?("form_1099") ? one_off_payees : []
      smaller = files?("form_1099") ? smaller_one_off_payees : []
      issues += payees.reject { |payee| payee[:status] == "identified" }.map do |payee|
        issue("PAYEE_IDENTITY_UNRESOLVED", one_off_payee_message(payee), warning_code: payee[:code], payee_key: payee[:payee_key])
      end
      duplicates = files?("form_1099") ? Form1099NecAggregator.duplicate_tin_groups(reportable_contractors) : []
      issues += duplicates.map do |group|
        issue("PAYEE_DUPLICATE_TIN", "#{group.map(&:full_name).to_sentence} have the same TIN, so they would get #{group.length} separate 1099s. " \
                                    "Correct the wrong TIN, or ask for help combining the records.", employee_id: group.first.id, employee_ids: group.map(&:id))
      end
      issues << issue("PAYEES_UNAVAILABLE", @contractor_error) if files?("form_1099") && !contractors_available?

      step(
        "people", "Employees and payees", issues,
        summary: issues.empty? ? "Every employee#{files?('form_1099') ? ' and 1099 payee' : ''} has a filing ID and address." : "Fix each one below. The list clears as you save.",
        data: {
          employees: employees,
          contractors: contractors,
          one_off_payees: payees,
          smaller_one_off_payees: smaller,
          w9_missing: w9_missing.map do |employee|
            { employee_id: employee.id, name: employee.full_name, edit_path: "/companies/#{company.id}/employees/#{employee.id}/edit" }
          end,
          duplicate_tins: duplicates.map { |group| group.map { |employee| { employee_id: employee.id, name: employee.full_name } } },
          link_candidates: files?("form_1099") ? link_candidates(payees + smaller) : [],
          linked_checks: files?("form_1099") ? linked_check_groups : [],
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
        @form_1099_report = Form1099NecAggregator.new(company, year).generate
        Array(@form_1099_report[:reportable_contractors])
      rescue ActiveRecord::RecordNotFound, ArgumentError => e
        @contractor_error = "1099 payees could not be loaded: #{e.message.delete_suffix('.')}. Fix the #{year} 1099-NEC setup, then reload this page."
        []
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { company_id: company.id, tax_year: year, source: "year_end_checklist" })
        @contractor_error = "1099 payees could not be loaded. Open the #{year} 1099-NEC report to see the problem, then reload this page."
        []
      end
    end

    # Every row of this checklist's 1099-NEC report, below the threshold too.
    def form_1099_all_rows
      form_1099_rows
      Array(@form_1099_report&.dig(:all_contractors))
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

    # Unlinked one-off payees below the threshold. They never block a
    # sign-off by themselves, but a check to a contractor the client already
    # pays belongs on that contractor's 1099, so they are listed to link.
    # could_reach_threshold: linked to a contractor who doesn't already get
    # a 1099 (the one with the largest year total), the combined total would
    # reach the threshold, so a 1099 would be due that otherwise isn't. A
    # check that would only add to an existing 1099 (a contractor at the
    # threshold, or under it with tax withheld) is listed but not flagged.
    def smaller_one_off_payees
      @smaller_one_off_payees ||= begin
        rows = form_1099_all_rows.reject { |row| row[:requires_filing] }
        threshold = @form_1099_report&.dig(:meta, :filing_threshold)&.to_d
        top = form_1099_all_rows.select { |row| row[:employee_id] && !row[:requires_filing] }
          .map { |row| row[:total_compensation].to_d }.max
        OneOffPayees.new(company: company, year: year, rows: rows).call.map do |payee|
          payee.except(:status, :acknowledgement, :acknowledgement_stale).merge(
            status: "below_threshold",
            could_reach_threshold: !top.nil? && !threshold.nil? && (top + payee[:total_compensation].to_d).round(2) >= threshold
          )
        end
      end
    end

    # Contractor records a one-off payee can be linked to. A record whose name
    # matches the payee's exactly is flagged so the screen can suggest it;
    # nothing is ever linked by name automatically.
    def link_candidates(payees)
      return [] if payees.all? { |payee| payee[:status] == "identified" }

      names = payees.to_set { |payee| payee[:name].to_s.strip.downcase }
      totals = form_1099_all_rows.select { |row| row[:employee_id] }.to_h { |row| [ row[:employee_id], row[:total_compensation].to_d.round(2).to_f ] }
      company.employees.contractor.order(:last_name, :first_name, :id).map do |employee|
        tin = employee.form_1099_tin
        {
          employee_id: employee.id,
          name: employee.full_name,
          business_name: employee.business_name,
          status: employee.status,
          # Payroll pay plus linked checks this year, so the screen can show
          # what the 1099 would total with the payee's checks.
          year_total: totals.fetch(employee.id, 0.0),
          tin_type: tin&.dig(:type),
          tin_last4: tin&.dig(:digits)&.last(4),
          has_address: [ employee.address_line1, employee.city, employee.state, employee.zip ].all?(&:present?),
          name_matches: [ employee.full_name, employee.business_name ].compact_blank.any? { |name| names.include?(name.strip.downcase) }
        }
      end
    end

    # One-off checks already linked to a contractor, so a wrong link can be
    # seen and undone.
    def linked_check_groups
      linked = issued_contractor_checks.select(&:payee_employee_id)
      return [] if linked.empty?

      employees = company.employees.where(id: linked.map(&:payee_employee_id)).index_by(&:id)
      linked.group_by(&:payee_employee_id).map do |employee_id, checks|
        {
          employee_id: employee_id,
          name: employees[employee_id]&.full_name,
          total: checks.sum(0.to_d) { |check| check.amount.to_d }.round(2).to_f,
          checks: checks.sort_by(&:id).map do |check|
            { id: check.id, check_number: check.check_number, payable_to: check.payable_to,
              payment_date: check.effective_payment_date&.iso8601, amount: check.amount.to_d.round(2).to_f }
          end
        }
      end.sort_by { |group| [ group[:name].to_s.downcase, group[:employee_id] ] }
    end

    def one_off_payee_message(payee)
      numbers = payee[:checks].filter_map { |check| check[:check_number] }
      checks = numbers.any? ? "check#{'s' if numbers.length > 1} #{numbers.to_sentence}" : "#{payee[:payment_count]} one-off check#{'s' unless payee[:payment_count] == 1}"
      prefix = payee[:acknowledgement_stale] ? "#{payee[:name]} needs to be resolved again: the checks changed, or the earlier note only said who the payee was. " : ""
      "#{prefix}#{payee[:name]} was paid #{ActiveSupport::NumberHelper.number_to_currency(payee[:total_compensation])} by #{checks} " \
        "with no contractor record or TIN. Link the checks to a contractor, or record why no 1099 is due."
    end

    def contractors_available?
      reportable_contractors
      @contractor_error.nil?
    end

    def person_row(employee, w2:)
      missing = []
      missing << "ssn" unless w2 ? employee.valid_filing_ssn? : employee.form_1099_tin.present?
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

    # -- Mark 1099s ready ----------------------------------------------

    # The 1099 sign-off, bound to Form1099InputsFingerprint. It is needed
    # only when some payee gets a 1099; it counts one issue until it matches
    # the current inputs. W-2 items never hold it up.
    def form_1099_ready_step(earlier_steps)
      key = "form_1099_ready"
      title = "Mark 1099s ready"
      state = form_1099_state
      blockers = form_1099_blockers_from(earlier_steps)
      rows = state.payee_rows
      readiness = state.readiness
      threshold = state.report&.dig(:meta, :filing_threshold)

      # A one-off payee not yet resolved may still become a 1099.
      may_be_due = rows.any? || one_off_payees.any? { |payee| payee[:status] != "identified" }

      issues = []
      if state.report.nil?
        issues << issue("FORM_1099_NOT_MARKED_READY", "The 1099 payees could not be loaded, so the 1099s can't be marked ready yet.")
      elsif may_be_due && !state.current?
        issues << issue("FORM_1099_NOT_MARKED_READY", readiness&.marked? ? "Payees, amounts or payer details changed after the #{year} 1099s were marked ready. Mark them ready again." : "Mark the #{year} 1099s ready once the steps above are done.")
      end
      # Smaller unlinked one-off payees never hold up the sign-off; the ones
      # that could reach the threshold with a contractor are pointed out.
      could_reach = state.report.nil? ? 0 : smaller_one_off_payees.count { |payee| payee[:could_reach_threshold] }
      smaller_note = could_reach.zero? ? "" : " #{could_reach} smaller one-off payee#{could_reach == 1 ? '' : 's'} could reach it with a contractor's pay; link any that went to a contractor in the employees and payees step."
      summary = if state.report.nil?
        "Fix the 1099 payee list in the employees and payees step first."
      elsif !may_be_due
        "No payee reached #{ActiveSupport::NumberHelper.number_to_currency(threshold, precision: 0)} in #{year}, so there are no 1099s to mark ready.#{smaller_note}"
      elsif state.current?
        "Marked ready#{readiness.marked_ready_at ? " on #{format_date(readiness.marked_ready_at.in_time_zone('Pacific/Guam'))}" : ''}#{readiness.marked_ready_by_name.present? ? " by #{readiness.marked_ready_by_name}" : ''}."
      else
        "This records your sign-off on the payees and amounts below."
      end
      reason = if company.practice_copy?
        "Not available in a practice copy."
      elsif !permissions[:can_mark_ready]
        "A manager or admin marks the 1099s ready."
      end

      step(
        key, title, issues,
        summary: summary,
        data: {
          readiness: readiness&.payload(fingerprint: state.fingerprint),
          inputs_fingerprint: state.fingerprint,
          can_mark_ready: state.report.present? && rows.any? && blockers.empty?,
          unavailable_reason: reason,
          blockers: blockers,
          remaining_before_ready: blockers.length,
          filing_threshold: threshold&.to_d&.round(2)&.to_f,
          payee_count: rows.length,
          total_compensation: rows.sum(0.to_d) { |row| row[:total_compensation].to_d }.round(2).to_f,
          no_1099_due_count: one_off_payees.count { |payee| payee[:status] == "identified" },
          smaller_one_off_count: state.report.nil? ? 0 : smaller_one_off_payees.length,
          smaller_could_reach_count: could_reach,
          payees: form_1099_payee_summaries(rows)
        }
      )
    end

    # What each 1099 will show, for the sign-off: the name, the TIN's last
    # four digits, the Box 1a amount, any Box 4 withholding and why the
    # payee gets a 1099.
    def form_1099_payee_summaries(rows)
      employees = company.employees.where(id: rows.map { |row| row[:employee_id] }).index_by(&:id)
      rows.filter_map do |row|
        employee = employees[row[:employee_id]]
        next unless employee

        tin = employee.form_1099_tin
        {
          employee_id: employee.id,
          name: employee.business_contractor? && employee.business_name.present? ? employee.business_name : employee.full_name,
          tin_type: tin&.dig(:type),
          tin_last4: tin&.dig(:digits)&.last(4),
          total_compensation: row[:total_compensation].to_d.round(2).to_f,
          federal_withheld: row[:federal_withheld].to_d.round(2).to_f,
          filing_reason: row[:filing_reason],
          linked_check_count: Array(row[:non_employee_check_ids]).length,
          edit_path: "/companies/#{company.id}/employees/#{employee.id}/edit"
        }
      end.sort_by { |payee| [ payee[:name].to_s.downcase, payee[:employee_id] ] }
    end

    # -- Steps 4 and 5 ---------------------------------------------------

    def w2_report
      return @w2_report if defined?(@w2_report)

      @w2_report = begin
        W2GuAggregator.new(company, year).generate
      rescue StandardError => e
        Rails.logger.error("W-2 checklist failed company_id=#{company.id} tax_year=#{year} error_class=#{e.class.name}")
        @w2_report_error = "W-2 totals could not be loaded. Open the W-2GU report to check payroll, then reload this checklist."
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
        elsif warning[:kind] == "history_review"
          "#{warning[:title]}: record a decision in Payroll history review."
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
      earlier_blockers = earlier_steps.sum { |step| step[:issues].count { |issue| !issue[:code].in?(FORM_1099_ONLY_CODES) && !issue[:code].in?(DEMO_EXPECTED_CODES) } }

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
        [ readiness, (W2FilingInputsFingerprint.new(company: company, year: year, report: w2_report).call if readiness && w2_report) ]
      end
    end

    # -- Step 8 ----------------------------------------------------------

    # A list of documents, each with a one-line explanation and a download.
    # Status "available" sits outside the checklist's done/needs-action
    # counting, which ignores this step entirely.
    # `steps` are the numbered steps above, so the summary can name the step
    # that makes the drafts final.
    def print_and_file_step(steps)
      key = "print_and_file"
      title = "Print and file"
      unless files_any?
        return waiting_step(key, title) unless decisions_recorded?

        return not_needed_step(key, title, "Cornerstone files no #{year} forms for this client.")
      end

      practice = company.practice_copy?
      groups = []
      if files?("w2_gu")
        readiness, fingerprint = w2_readiness
        final = !practice && W2GuOfficialCopies.final?(company: company, year: year, readiness: readiness, fingerprint: fingerprint)
        groups << { forms: "W-2s", step: steps.find { |step| step[:key] == "mark_ready" }, final: final, documents: w2_copy_documents(final) }
      end
      if files?("form_1099")
        final = form_1099_state.final
        none = no_1099_filings?
        groups << { forms: "1099s", step: steps.find { |step| step[:key] == "form_1099_ready" }, final: final, none_needed: none,
                    documents: form_1099_documents(final, none_needed: none) }
      end
      # A year with no 1099s has nothing to mark ready or file.
      pending = groups.reject { |group| group[:none_needed] }
      none_note = ("No 1099 filings are needed for #{year}: no payee gets a 1099." if pending.length < groups.length)
      summary = if practice
        "This is a practice copy, so every document is a draft. Review them, but don't hand them out or file them."
      elsif pending.empty?
        none_note
      elsif pending.all? { |group| group[:final] }
        "The #{year} #{pending.map { |group| group[:forms] }.join(' and ')} are marked ready. Download each document below."
      elsif pending.one?
        "Drafts until the #{pending.first[:forms]} are marked ready in step #{pending.first[:step]&.fetch(:number)}. Review them, but don't hand them out yet."
      else
        drafts = pending.reject { |group| group[:final] }
        "#{drafts.map { |group| "#{group[:forms].delete_suffix('s')} documents are drafts until the #{group[:forms]} are marked ready in step #{group[:step]&.fetch(:number)}" }.join('. ')}. " \
          "Review drafts, but don't hand them out yet."
      end
      summary = [ summary, none_note ].compact.uniq.join(" ") unless practice
      {
        key: key, number: STEP_KEYS.index(key) + 1, title: title, status: "available",
        summary: summary,
        issues: [],
        data: {
          final: pending.any? && pending.all? { |group| group[:final] },
          no_1099_filings: groups.any? { |group| group[:none_needed] },
          documents: groups.flat_map { |group| group[:documents] }
        }
      }
    end

    # Cornerstone files the 1099s, but no payee gets one and none could: no
    # contractor row, no one-off payee still undecided, and no smaller
    # one-off payee that could reach the threshold with a contractor.
    def no_1099_filings?
      state = form_1099_state
      state.report.present? && state.payee_rows.empty? &&
        one_off_payees.all? { |payee| payee[:status] == "identified" } &&
        smaller_one_off_payees.none? { |payee| payee[:could_reach_threshold] }
    end

    # The official 1099-NEC copies: one recipient copy per contractor and the
    # payer's record with full TINs.
    def form_1099_documents(final, none_needed: false)
      state = form_1099_state
      count = state.payee_rows.length
      unavailable = if !Form1099NecOfficialCopies.supported_tax_year?(year)
        Form1099NecOfficialCopies.unsupported_message(year)
      elsif state.report.nil?
        "The 1099 payees could not be loaded. Fix them in the employees and payees step first."
      elsif count.zero?
        "No payee reached #{ActiveSupport::NumberHelper.number_to_currency(state.report.dig(:meta, :filing_threshold), precision: 0)} in #{year}, so there are no 1099s."
      end
      contractors = "#{count} contractor#{'s' unless count == 1}"
      [
        {
          key: "form_1099_recipient_copies", title: "1099-NEC for each contractor (Copy B)",
          description: "Print and give or mail to each contractor by #{format_date(furnish_due_date)}.",
          detail: "#{contractors}, one sheet each, by name: Copy B on the front, the IRS instructions on the back. " \
                  "Print double-sided. TINs show only the last four digits.",
          contains_full_ssn: false, contains_full_tin: false, path: "/admin/reports/form_1099_nec_recipient_copies"
        },
        {
          key: "form_1099_payer_record", title: "1099-NEC payer record",
          description: "Keep with your filing records. Not mailed when you e-file with Guam DRT.",
          detail: "#{contractors}, one form a page, on the IRS Copy 1 page. Each download is recorded in the activity log.",
          contains_full_ssn: false, contains_full_tin: true, path: "/admin/reports/form_1099_nec_payer_record"
        }
      ].map do |document|
        restriction = if document[:contains_full_tin] && company.practice_copy?
          "Not available in a practice copy — it contains full TINs."
        elsif document[:contains_full_tin] && !permissions[:can_mark_ready]
          "Needs client-management access (contains full TINs)."
        end
        reason = unavailable || restriction
        document.except(:path).merge(
          format: "pdf", draft: !final, available: reason.nil?, unavailable_reason: reason,
          download: { path: document[:path], params: { year: year } }
        )
      end + form_1099_filing_documents(final, payee_count: count, none_needed: none_needed)
    end

    # The Pub 1220 e-file for GuamTax and the 1096 totals sheet. Final only
    # on the same "1099s ready" sign-off as the copies (Form1099Readiness).
    # Built from the payees the sign-off covers, so with none there is no file.
    def form_1099_filing_documents(final, payee_count:, none_needed:)
      restriction = if company.practice_copy?
        "Not available in a practice copy"
      elsif !permissions[:can_mark_ready]
        "Needs client-management access"
      end
      reason = if year != 2026
        "Only tax year 2026 is supported"
      elsif form_1099_state.report.nil?
        "The 1099 payees could not be loaded. Fix them in the employees and payees step first."
      elsif none_needed
        "No 1099 filings are needed for #{year}: no payee gets a 1099."
      elsif payee_count.zero?
        "No contractor gets a 1099 yet. Resolve the one-off payees in the employees and payees step first."
      end
      [
        [ "form_1099_pub1220", "1099 e-file for GuamTax", "txt" ],
        [ "form_1096_totals", "1096 totals (for your records)", "pdf" ]
      ].map do |path, title, format|
        efile = format == "txt"
        unavailable = reason || (restriction && (efile ? "#{restriction} — it contains full TINs." : "#{restriction}."))
        unavailable ||= demo_efile_reason if efile
        {
          key: path, title: title, format: format, draft: !final,
          description: efile ? "Upload to GuamTax after the 1099s are marked ready." : "For your records — not for filing.",
          detail: "Totals use reportable payees only. Each download is recorded in the activity log.",
          contains_full_ssn: efile, contains_full_tin: efile, available: unavailable.nil?, unavailable_reason: unavailable,
          draft_confirmation: !final && efile ? "Test file only — review it, but don't upload it as your filing." : nil,
          download: { path: "/admin/reports/#{path}", params: { year: year, mode: final ? "final" : "draft" } }
        }
      end
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
          description: "Print and give to each employee by #{format_date(furnish_due_date)}.",
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
        reason = unavailable || (drt_unavailable_reason if drt)
        document.merge(
          format: "pdf", draft: !final, available: reason.nil?, unavailable_reason: reason,
          download: { path: "/admin/reports/#{drt ? 'w2_gu_copy_1_drt' : 'w2_gu_employee_copies'}", params: { year: year } }
        )
      end + wage_filing_documents(final, unavailable)
    end

    def wage_filing_documents(final, unavailable)
      confirmation = "Test file only — review it, but don't upload it as your filing."
      [
        {
          key: "w2_efile", title: "W-2 e-file (SSA and GuamTax)", format: "txt",
          description: "One wage file to upload to SSA (BSO) and GuamTax after the W-2s are marked ready.",
          detail: "Check a draft in AccuWage first. Each download is recorded in the activity log.",
          contains_full_ssn: true, draft_confirmation: confirmation, path: "/admin/reports/w2_gu_efw2"
        },
        {
          key: "w3ss_totals", title: "W-3SS totals (for your records)", format: "pdf",
          description: "Keep this totals sheet with your filing records; it is not an agency filing.",
          detail: "The employer totals come from the same W-2 wages as the e-file.",
          contains_full_ssn: false, path: "/admin/reports/w3ss_pdf"
        }
      ].map do |document|
        restriction = if document[:contains_full_ssn]
          drt_unavailable_reason
        elsif company.practice_copy?
          "Not available in a practice copy."
        end
        reason = unavailable || restriction || (demo_efile_reason if document[:key] == "w2_efile")
        document.except(:path).merge(
          draft: !final, draft_confirmation: final ? nil : document[:draft_confirmation],
          available: reason.nil?, unavailable_reason: reason,
          download: { path: document[:path], params: { year: year, mode: final ? "final" : "draft" } }
        )
      end
    end

    # Copy 1 carries full SSNs: never in a practice workspace, and only for
    # staff who may sign off the W-2s.
    def drt_unavailable_reason
      if company.practice_copy?
        "Not available in a practice copy — it contains full SSNs."
      elsif !permissions[:can_mark_ready]
        "Needs client-management access (contains full SSNs)."
      end
    end

    # A demo company prepares, reviews and downloads every copy like a live
    # client, and never produces an e-file outside DEPLOYMENT_ENV=local.
    def demo_efile_reason
      Company::DEMO_UNAVAILABLE_MESSAGE if company.demo? && !LocalDeployment.local?
    end

    # January 31 of the next year, or the next business day after a weekend.
    def furnish_due_date
      FilingProgress.due_date(year)
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
      blocking = issues.reject { |entry| entry[:code].in?(DEMO_EXPECTED_CODES) }
      {
        key: key,
        number: STEP_KEYS.index(key) + 1,
        title: title,
        status: blocking.empty? ? "done" : "action_needed",
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
