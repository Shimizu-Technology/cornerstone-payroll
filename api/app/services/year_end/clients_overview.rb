# frozen_string_literal: true

module YearEnd
  # The year-end clients list: every live client a staff member can open, with
  # a plain status and the things left to fix, worst first.
  #
  # W-2 clients reuse employee preflight only at the current input revision.
  # Other clients use grouped lookups.
  # Decisions, employer details, employees and 1099 payees are checked the
  # same way the checklist checks them. The numeric checks (reconciliation,
  # judgment warnings, overlap, fingerprint) run on the client's own
  # checklist, and mark ready enforces them, so the list shows Ready only
  # when the W-2s are marked ready and the last successful check (mark ready
  # or a ready checklist) was made at the current input revision, which
  # changes on any create, update or delete the checklist reads. Anything
  # else shows known issues first, or "Check needed" when none are known.
  # Missing employee checks are queued without aggregating on the request.
  class ClientsOverview
    def initialize(user:, year:, enqueue_missing_checks: true)
      @user = user
      @year = Integer(year)
      @enqueue_missing_checks = enqueue_missing_checks
    end

    def call
      TenantScope.as_system(reason: "Read year-end status across authorized companies") { build_overview }
    end

    private def build_overview
      rows = candidate_companies.map { |company| row(company) }
      live_rows = rows.reject { |entry| entry[:demo] }
      {
        tax_year: year,
        # Undecided clients first: nothing else can start until step 1 is answered.
        clients: rows.sort_by { |row| [ status_rank(row[:status]), row[:w2] && row[:form_1099] ? 1 : 0, -row[:issue_count].to_i, row[:name].downcase ] },
        counts: {
          needs_action: live_rows.count { |row| row[:status] == "needs_action" },
          check_needed: live_rows.count { |row| row[:status] == "check_needed" },
          ready: live_rows.count { |row| row[:status] == "ready" },
          not_filing: live_rows.count { |row| row[:status] == "not_filing" }
        },
        filing_reminder_count: Date.current >= Date.new(year + 1, 1, 1) ? live_rows.count { |row| row[:filing_progress].any? { |filing| filing[:status].in?(%w[not_filed rejected needs_correction accepted_with_errors]) } } : nil,
        hidden: {
          test_workspaces: accessible_companies.count(&:practice_copy?),
          inactive_without_payroll: accessible_companies.count { |company| company.live_payroll? && !company.active? && !relevant_inactive?(company) }
        }
      }
    end

    private

    attr_reader :user, :year

    def year_range
      Date.new(year, 1, 1)..Date.new(year, 12, 31)
    end

    def accessible_companies
      @accessible_companies ||= Company.where(id: user&.accessible_company_ids || []).order(:name).to_a
    end

    def company_ids
      @company_ids ||= accessible_companies.map(&:id)
    end

    # Operating companies (live clients and active demos) appear in the Year-End
    # queue. Practice copies never file. An inactive live client is listed only
    # while it still has this year's payroll, reportable one-off contractor
    # checks or a year-end decision.
    def candidate_companies
      accessible_companies.select(&:operating?).select { |company| company.active? || (company.live_payroll? && relevant_inactive?(company)) }
    end

    def relevant_inactive?(company)
      native_payroll_counts[company.id].to_i.positive? || historical_payroll_counts[company.id].to_i.positive? ||
        one_off_payee_company_ids.include?(company.id) || responsibilities.key?(company.id)
    end

    def row(company)
      decisions = responsibilities.fetch(company.id, {})
      w2 = decisions["w2_gu"]
      form_1099 = decisions["form_1099"]
      issues = []
      issues << { code: "FILER_NOT_CHOSEN", label: "Choose who files" } unless w2
      issues << { code: "FILER_NOT_CHOSEN", label: "Choose who files" } unless form_1099
      files_w2 = w2&.responsible_party == "cornerstone"
      files_1099 = form_1099&.responsible_party == "cornerstone"

      # Like the checklist, a recorded Cornerstone decision starts these checks
      # without waiting for the other decision.
      if files_w2 || files_1099
        issues << { code: "EMPLOYER_EIN_MISSING", label: "EIN missing" } if company.ein.blank?
        if [ company.address_line1, company.city, company.state, company.zip ].any?(&:blank?)
          issues << { code: "EMPLOYER_ADDRESS_INCOMPLETE", label: "Employer address incomplete" }
        end
        issues << { code: "EMPLOYER_PHONE_MISSING", label: "Employer phone missing" } if company.phone.blank?
        issues << { code: "EMPLOYER_EMAIL_MISSING", label: "Employer email missing" } if company.email.blank?
        if files_w2
          employees_missing_details.fetch(company.id, {}).fetch(:employees, 0).times do
            issues << { code: "EMPLOYEE_DETAILS_MISSING", label: "Employees missing an SSN or address" }
          end
        end
        issues.concat(payee_issues(company)) if files_1099
      end

      if files_w2
        issues << { code: "EMPLOYER_CONTACT_NAME_MISSING", label: "Add the employer filing contact name" } if company.filing_contact_name.blank?
        if year == 2026
          preflight = Checklist.new(company: company, year: year, user: user, responsibilities: decisions)
          issues.concat(preflight.efw2_employer_issues.map { |entry| { code: entry[:code], label: entry[:message] } })
          stored = efile_checks[company.id]
          efile_current = stored.present? && stored[:revision] == input_revisions[company.id]
          # The sign-off flag also depends on the ready mark, which the input
          # revision does not cover.
          sign_off_current = efile_current && stored[:readiness] == EfileCheck.readiness_stamp(readinesses[company.id])
          EfileCheck.enqueue(company.id, year, input_revisions[company.id]) if @enqueue_missing_checks && !sign_off_current
          if efile_current
            stored_issues = stored[:issues].reject { |entry| Checklist::DEMO_EXPECTED_CODES.include?(entry[:code]) }
            issues.concat(stored_issues.map { |entry| { code: entry[:code], label: entry[:message] } })
          end
        end
      end
      readiness = readinesses[company.id]
      marked = files_w2 && readiness&.status == "filing_ready" && readiness.marked_ready_at.present?
      unchanged = ready_checks[company.id].present? && ready_checks[company.id] == input_revisions[company.id]
      # The live ready mark wins: a cached check can add a sign-off, never remove one.
      sign_off_needed = !marked || (sign_off_current && stored[:sign_off_needed] == true)
      if files_w2 && sign_off_needed
        issues << { code: "W2_NOT_MARKED_READY", label: "Check the numbers and mark W-2s ready" }
      end
      # 1099-only clients are fully checked above; the W-2 sign-off is the
      # only part the list cannot recompute.
      sign_off_unknown = files_w2 && year == 2026 && !sign_off_current
      check_needed = (marked && (!unchanged || sign_off_unknown) && !sign_off_needed) || (files_w2 && year == 2026 && !efile_current)

      status = if issues.any?
        "needs_action"
      elsif check_needed
        "check_needed"
      elsif !files_w2 && !files_1099
        "not_filing"
      else
        "ready"
      end

      {
        company_id: company.id,
        name: company.name,
        demo: company.demo?,
        active: company.active?,
        status: status,
        issue_count: status == "check_needed" ? nil : issues.length,
        efile_check_pending: !!(files_w2 && year == 2026 && !efile_current),
        issue_summary: summarize(issues),
        w2: decision_summary(w2),
        form_1099: decision_summary(form_1099),
        w2_employee_count: w2_population.fetch(company.id, Set.new).size,
        employee_details: files_w2 ? { missing_ssn: 0, missing_address: 0 }.merge(employees_missing_details.fetch(company.id, {}).slice(:missing_ssn, :missing_address)) : nil,
        marked_ready_at: marked ? readiness.marked_ready_at.iso8601 : nil,
        check_reason: status == "check_needed" ? (marked ? "Something may have changed since the W-2s were marked ready. Open the checklist to re-check." : "Open the checklist to check the current employee details and W-2 numbers.") : nil,
        filing_progress: FilingProgress.new(company: company, year: year,
          decisions: decisions.values.select { |decision| decision.responsible_party == "cornerstone" }.map(&:filing_type),
          records: filing_records.fetch(company.id, []), downloads: filing_downloads.fetch(company.id, {}),
          form_1099_due: !files_1099 || form_1099_filing_may_be_due?(company)).call,
        checklist_path: "/companies/#{company.id}/year-end?year=#{year}"
      }
    end

    def filing_records
      @filing_records ||= PayrollFilingRecord.where(company_id: company_ids, tax_year: year, quarter: nil).group_by(&:company_id)
    end

    def filing_downloads
      @filing_downloads ||= AuditLog.where(company_id: company_ids, action: %w[efw2#download pub1220#download])
        .where("metadata->>'file_digest' ~ '^[0-9a-f]{64}$'")
        .where("metadata->>'digest_alg' = ?", FilingFileDigest::ALGORITHM)
        .where("metadata->>'year' = ? AND metadata->>'mode' = 'final'", year.to_s)
        .select("DISTINCT ON (company_id, action) audit_logs.*").order(:company_id, :action, created_at: :desc, id: :desc)
        .each_with_object({}) do |log, result|
          type = log.action == "efw2#download" ? "w2_gu_w3_ss" : "form_1099_nec"
          (result[log.company_id] ||= {})[type] ||= log
        end
    end

    def summarize(issues)
      issues.group_by { |issue| issue[:code] }.map do |code, group|
        { code: code, label: group.first[:label], count: group.length }
      end
    end

    def decision_summary(record)
      return unless record

      {
        responsible_party: record.responsible_party,
        label: Checklist::PARTY_LABELS.fetch(record.responsible_party),
        prior_provider_through: record.prior_provider_through&.iso8601
      }
    end

    def status_rank(status)
      { "needs_action" => 0, "check_needed" => 1, "ready" => 2, "not_filing" => 3 }.fetch(status)
    end

    # -- Batched lookups -------------------------------------------------

    def responsibilities
      @responsibilities ||= PayrollFilingResponsibility
        .where(company_id: company_ids, tax_year: year, quarter: nil, filing_type: PayrollFilingResponsibility::YEAR_END_FILING_TYPES)
        .group_by(&:company_id)
        .transform_values { |records| records.index_by(&:filing_type) }
    end

    def readinesses
      @readinesses ||= W2FilingReadiness.where(company_id: company_ids, year: year).index_by(&:company_id)
    end

    def efile_checks
      @efile_checks ||= EfileCheck.read_many(company_ids, year)
    end

    def ready_checks
      @ready_checks ||= ReadyCheck.read_many(company_ids, year)
    end

    def input_revisions
      @input_revisions ||= InputRevision.for(company_ids, year)
    end

    def native_payroll_counts
      @native_payroll_counts ||= PayPeriod.reportable_committed.where(company_id: company_ids, pay_date: year_range)
                                          .group(:company_id).count
    end

    def historical_payroll_counts
      @historical_payroll_counts ||= HistoricalPaycheck.joins(:historical_import_batch)
        .where(company_id: company_ids, pay_date: year_range, historical_import_batches: { status: "locked" })
        .group(:company_id).count
    end

    # The same W-2 population as W2GuFilingPopulation, for every company at
    # once: committed non-contractor payroll plus each locked import's latest
    # applied YTD bridge.
    def w2_population
      @w2_population ||= begin
        population = Hash.new { |hash, key| hash[key] = Set.new }
        PayrollItem.joins(:pay_period)
                   .where(company_id: company_ids)
                   .financially_reportable.reportable
                   .where.not(employment_type: "contractor")
                   .where(pay_periods: { id: PayPeriod.reportable_committed.where(company_id: company_ids, pay_date: year_range).select(:id) })
                   .distinct.pluck(:company_id, :employee_id)
                   .each { |company_id, employee_id| population[company_id] << employee_id }
        HistoricalEmployeeYtdBalance.where(historical_ytd_bridge_id: latest_bridge_ids, company_id: company_ids, tax_year: year)
                                    .where.not(employee_id: nil)
                                    .distinct.pluck(:company_id, :employee_id)
                                    .each { |company_id, employee_id| population[company_id] << employee_id }
        population
      end
    end

    def latest_bridge_ids
      batches = HistoricalImportBatch.joins(:historical_paychecks)
                                     .where(company_id: company_ids, status: "locked", historical_paychecks: { pay_date: year_range })
                                     .distinct.pluck(:id)
      return [] if batches.empty?

      HistoricalYtdBridge.where(historical_import_batch_id: batches, status: "applied")
                         .select("DISTINCT ON (historical_import_batch_id) id")
                         .order(:historical_import_batch_id, revision: :desc, id: :desc)
                         .map(&:id)
    end

    def employees_missing_details
      @employees_missing_details ||= begin
        ids = w2_population.values.flat_map(&:to_a)
        Employee.where(id: ids).each_with_object(Hash.new { |hash, key| hash[key] = Hash.new(0) }) do |employee, counts|
          missing_ssn = !employee.valid_filing_ssn?
          missing_address = [ employee.address_line1, employee.city, employee.state, employee.zip ].any?(&:blank?)
          counts[employee.company_id][:missing_ssn] += 1 if missing_ssn
          counts[employee.company_id][:missing_address] += 1 if missing_address
          counts[employee.company_id][:employees] += 1 if missing_ssn || missing_address
        end
      end
    end

    # -- 1099 payees: the same population and checks as the checklist ------

    # The 1099 sign-off is needed while some payee gets a 1099 and the ready
    # mark does not match the current inputs: the checklist's rule.
    def payee_issues(company)
      sign_off = { code: "FORM_1099_NOT_MARKED_READY", label: "Mark 1099s ready" }
      return [ { code: "PAYEES_UNAVAILABLE", label: "1099 payees could not be checked" }, sign_off ] unless form_1099_threshold

      details = form_1099_payees.fetch(company.id, {})
      issues = Array.new(details[:missing].to_i) { { code: "PAYEE_DETAILS_MISSING", label: "1099 payees missing a TIN or address" } } +
        Array.new(details[:w9_missing].to_i) { { code: "PAYEE_W9_MISSING", label: "W-9 not on file" } } +
        Array.new(details[:duplicate_tins].to_i) { { code: "PAYEE_DUPLICATE_TIN", label: "1099 payees sharing one TIN" } } +
        Array.new(unidentified_one_off_payees[company.id].to_i) { { code: "PAYEE_IDENTITY_UNRESOLVED", label: "One-off 1099 payees to resolve" } }
      issues << sign_off if form_1099_may_be_due?(company) && !form_1099_signed_off?(company)
      issues
    end

    # Some payee gets a 1099, or a one-off payee not yet resolved may still
    # become one. Payees that can't be checked count as due.
    def form_1099_may_be_due?(company)
      return true unless form_1099_threshold

      form_1099_payees.fetch(company.id, {})[:reportable].to_i.positive? || unidentified_one_off_payees[company.id].to_i.positive?
    end

    # The checklist's no-1099 rule for filing progress: also due while a
    # smaller one-off payee linked to the largest contractor short of the
    # threshold would reach it. That case never holds up the sign-off.
    def form_1099_filing_may_be_due?(company)
      return true if form_1099_may_be_due?(company)

      top = largest_unreported_contractor[company.id]
      smaller = largest_smaller_one_off[company.id]
      !top.nil? && !smaller.nil? && (top + smaller).round(2) >= form_1099_threshold
    end

    def largest_unreported_contractor
      form_1099_payees
      @largest_unreported_contractor || {}
    end

    # The largest unlinked one-off payee short of the threshold, per client.
    def largest_smaller_one_off
      @largest_smaller_one_off ||= OneOffPayees.issued_check_groups([], year, checks: issued_contractor_checks)
        .reject { |key, _payments| reportable_one_off_groups.key?(key) }
        .each_with_object({}) do |((company_id, _name), payments), result|
          total = payments.sum(0.to_d) { |check| check.amount.to_d }
          result[company_id] = [ result[company_id], total ].compact.max
        end
    end

    # A ready mark is checked against the live inputs only when there is one;
    # that is the only per-client 1099 work the list does.
    def form_1099_signed_off?(company)
      return false unless form_1099_readinesses[company.id]&.marked?

      Form1099NecFilingState.call(company: company, year: year).current?
    end

    def form_1099_readinesses
      @form_1099_readinesses ||= Form1099FilingReadiness.where(company_id: form_1099_company_ids, tax_year: year).index_by(&:company_id)
    end

    def form_1099_company_ids
      @form_1099_company_ids ||= responsibilities.select { |_id, decisions| decisions["form_1099"]&.responsible_party == "cornerstone" }.keys
    end

    def form_1099_threshold
      return @form_1099_threshold if defined?(@form_1099_threshold)

      @form_1099_threshold = InformationReturnThreshold.find_by(form_type: "1099_nec", tax_year: year)&.threshold_amount&.to_d
    end

    # Form1099NecAggregator's reportable contractors (payroll plus linked
    # one-off checks), for every 1099 client at once: how many there are, how
    # many lack a TIN or address, how many have no W-9 on file, and how many
    # groups share one TIN.
    def form_1099_payees
      @form_1099_payees ||= begin
        totals = Hash.new(0.to_d)
        withholding = Hash.new(0.to_d)
        companies = {}
        unless form_1099_company_ids.empty? || form_1099_threshold.nil?
          PayrollItem.joins(:pay_period)
            .where(company_id: form_1099_company_ids, employment_type: "contractor")
            .financially_reportable
            .where(pay_periods: { id: PayPeriod.reportable_committed.where(company_id: form_1099_company_ids, pay_date: year_range).select(:id) })
            .group(:company_id, :employee_id)
            .pluck(:company_id, :employee_id, Arel.sql("SUM(gross_pay)"), Arel.sql("SUM(COALESCE(withholding_tax, 0))"))
            .each do |company_id, employee_id, gross, withheld|
              companies[employee_id] = company_id
              totals[employee_id] += gross.to_d
              withholding[employee_id] += withheld.to_d
            end
          OneOffPayees.linked_totals(issued_contractor_checks.select { |check| check.company_id.in?(form_1099_company_ids) })
            .each do |(company_id, employee_id), total|
              companies[employee_id] = company_id
              totals[employee_id] += total
            end
        end
        # The aggregator's rule: the threshold after linked checks, or any withholding.
        reportable_ids = totals.keys.select { |id| totals[id].round(2) >= form_1099_threshold || !withholding[id].zero? }
        # The checklist's "could reach the threshold" base, per client.
        @largest_unreported_contractor = (totals.keys - reportable_ids).group_by { |id| companies[id] }
          .transform_values { |ids| ids.map { |id| totals[id] }.max }
        Employee.where(company_id: form_1099_company_ids, id: reportable_ids).group_by(&:company_id).transform_values do |employees|
          {
            reportable: employees.length,
            missing: employees.count { |employee| employee.form_1099_tin.nil? || [ employee.address_line1, employee.city, employee.state, employee.zip ].any?(&:blank?) },
            w9_missing: employees.count { |employee| !employee.w9_on_file? },
            duplicate_tins: Form1099NecAggregator.duplicate_tin_groups(employees).length
          }
        end
      end
    end

    # Printed or paid contractor checks of every candidate company, linked or
    # not, in one query.
    def issued_contractor_checks
      @issued_contractor_checks ||= OneOffPayees.issued_checks(accessible_companies.select(&:operating?).map(&:id), year)
    end

    # Form1099NecAggregator's unlinked one-off contractor payees (printed or
    # paid contractor checks, grouped by exact payee name) that reach the
    # threshold, for every candidate company whatever its decision.
    def reportable_one_off_groups
      @reportable_one_off_groups ||= OneOffPayees.reportable_groups(
        OneOffPayees.issued_check_groups([], year, checks: issued_contractor_checks), form_1099_threshold
      )
    end

    def one_off_payee_company_ids
      @one_off_payee_company_ids ||= reportable_one_off_groups.keys.to_set(&:first)
    end

    # The reportable one-off payees of each 1099 client with no current
    # identification on record.
    def unidentified_one_off_payees
      @unidentified_one_off_payees ||= begin
        if form_1099_company_ids.empty? || form_1099_threshold.nil?
          {}
        else
          acknowledgements = YearEndAcknowledgement.where(company_id: form_1099_company_ids, tax_year: year)
            .where("warning_code LIKE ?", "#{OneOffPayees::CODE_PREFIX}%").pluck(:company_id, :warning_code, :warning_digest)
            .to_h { |company_id, code, digest| [ [ company_id, code ], digest ] }
          reportable_one_off_groups.each_with_object(Hash.new(0)) do |((company_id, name), payments), counts|
            next unless company_id.in?(form_1099_company_ids)

            code = OneOffPayees.code_for("non_employee_check:#{payments.map(&:id).min}")
            digest = OneOffPayees.digest_for(code, checks: payments, name: name)
            counts[company_id] += 1 unless acknowledgements[[ company_id, code ]] == digest
          end
        end
      end
    end
  end
end
