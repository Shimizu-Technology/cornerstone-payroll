# frozen_string_literal: true

module YearEnd
  # The year-end clients list: every live client a staff member can open, with
  # a plain status and the things left to fix, worst first.
  #
  # Every check here is a fixed number of grouped queries for the whole list.
  # The numeric checks (reconciliation, judgment warnings, fingerprint
  # freshness) run on the client's own checklist, so a client the list calls
  # "ready" was marked ready and has had no payroll committed since.
  class ClientsOverview
    def initialize(user:, year:)
      @user = user
      @year = Integer(year)
    end

    def call
      rows = candidate_companies.map { |company| row(company) }
      {
        tax_year: year,
        # Undecided clients first: nothing else can start until step 1 is answered.
        clients: rows.sort_by { |row| [ status_rank(row[:status]), row[:w2] && row[:form_1099] ? 1 : 0, -row[:issue_count], row[:name].downcase ] },
        counts: {
          needs_action: rows.count { |row| row[:status] == "needs_action" },
          ready: rows.count { |row| row[:status] == "ready" },
          not_filing: rows.count { |row| row[:status] == "not_filing" }
        },
        hidden: {
          test_workspaces: accessible_companies.count(&:test_workspace?),
          inactive_without_payroll: accessible_companies.count { |company| !company.test_workspace? && !company.active? && !relevant_inactive?(company) }
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

    # Test workspaces never file. An inactive record is listed only while it
    # still has this year's payroll or a year-end decision, so staff can say it
    # files no forms instead of leaving it unanswered.
    def candidate_companies
      accessible_companies.reject(&:test_workspace?).select { |company| company.active? || relevant_inactive?(company) }
    end

    def relevant_inactive?(company)
      native_payroll_counts[company.id].to_i.positive? || historical_payroll_counts[company.id].to_i.positive? ||
        responsibilities.key?(company.id)
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

      if w2 && form_1099 && (files_w2 || files_1099)
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
      end

      readiness = readinesses[company.id]
      marked_ready = files_w2 && readiness&.status == "filing_ready" &&
        (latest_commits[company.id].nil? || readiness.marked_ready_at.nil? || latest_commits[company.id] <= readiness.marked_ready_at)
      changed_since_ready = files_w2 && readiness&.status == "filing_ready" && !marked_ready
      if files_w2 && !marked_ready
        issues << { code: "W2_NOT_MARKED_READY", label: changed_since_ready ? "Payroll changed since marked ready" : "Check the numbers and mark W-2s ready" }
      end

      status = if issues.any?
        "needs_action"
      elsif !files_w2 && !files_1099
        "not_filing"
      else
        "ready"
      end

      {
        company_id: company.id,
        name: company.name,
        active: company.active?,
        status: status,
        issue_count: issues.length,
        issue_summary: summarize(issues),
        w2: decision_summary(w2),
        form_1099: decision_summary(form_1099),
        w2_employee_count: w2_population.fetch(company.id, Set.new).size,
        employee_details: files_w2 ? { missing_ssn: 0, missing_address: 0 }.merge(employees_missing_details.fetch(company.id, {}).slice(:missing_ssn, :missing_address)) : nil,
        marked_ready_at: marked_ready ? readiness.marked_ready_at&.iso8601 : nil,
        checklist_path: "/companies/#{company.id}/year-end?year=#{year}"
      }
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
      { "needs_action" => 0, "ready" => 1, "not_filing" => 2 }.fetch(status)
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

    def latest_commits
      @latest_commits ||= PayPeriod.reportable_committed.where(company_id: company_ids, pay_date: year_range)
                                   .group(:company_id).maximum(:committed_at)
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
  end
end
