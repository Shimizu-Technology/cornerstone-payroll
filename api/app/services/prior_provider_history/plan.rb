# frozen_string_literal: true

module PriorProviderHistory
  class Plan
    attr_reader :company, :payload, :errors, :periods, :run_ids

    def initialize(company:, payload:)
      @company = company
      raise ArgumentError, "History payload must be an object" unless payload.is_a?(Hash)
      @payload = payload.deep_stringify_keys
      raise ArgumentError, "Verify employee identities against the existing roster" unless @payload["identities"].is_a?(Hash)
      @errors = []
      @periods = @payload["periods"]
      unless periods.is_a?(Array) && periods.size.in?(1..SourceAdapter::MAX_RUNS) && periods.all? { |row| row.is_a?(Hash) && row["paychecks"].is_a?(Array) && row["paychecks"].all? { |check| check.is_a?(Hash) } }
        raise ArgumentError, "Supply 1–#{SourceAdapter::MAX_RUNS} periods, each with employee paycheck rows"
      end
      raise ArgumentError, "Too many paychecks" if periods.sum { |row| row["paychecks"].size } > SourceAdapter::MAX_PAYCHECKS
      @run_ids = periods.filter_map { |row| row["run_id"] }.map { |id| Integer(id.to_s, 10) }
    end

    def call
      validate!
      self
    rescue ArgumentError, Date::Error, KeyError => e
      errors << e.message
      self
    end

    def ready? = errors.empty?
    def digest = Digest::SHA256.hexdigest(JSON.generate(QuickbooksHistory::CanonicalJson.normalize(payload)))
    def tax_year = Integer(payload.fetch("tax_year").to_s, 10)
    def takeover_on = Date.iso8601(payload.fetch("takeover_on").to_s)
    def totals = Amounts.totals(periods.flat_map { |period| period.fetch("paychecks") })

    private

    def validate!
      raise ArgumentError, "Prior-provider onboarding requires a live client" if company.test_workspace?
      raise ArgumentError, "Select 1–#{SourceAdapter::MAX_RUNS} periods" unless periods.size.in?(1..SourceAdapter::MAX_RUNS)
      raise ArgumentError, "Tax year must be 2000–2200 and match the takeover date" unless tax_year.in?(2000..2200) && takeover_on.year == tax_year
      raise ArgumentError, "Enter the previous provider's name" if payload["provider_name"].to_s.strip.blank? || payload["provider_name"].to_s.length > 200
      raise ArgumentError, "Confirm complete same-employer history and paid status" unless payload["complete_history_confirmed"] == true && payload["same_employer_confirmed"] == true
      raise ArgumentError, "A run can only be selected once" if run_ids.uniq.size != run_ids.size
      raise ArgumentError, "Each period requires a unique source key" if periods.any? { |row| row["key"].to_s.blank? || row["key"].to_s.length > 200 }
      raise ArgumentError, "Period source references must be unique" if periods.map { |p| p["key"] }.uniq.size != periods.size
      existing = HistoricalPaycheck.joins(:historical_import_batch).where(company_id: company.id, pay_date: Date.new(tax_year, 1, 1)..Date.new(tax_year, 12, 31))
        .where.not(historical_import_batches: { status: %w[failed reversed] })
      raise ArgumentError, "This year already has historical payroll; do not overlap or double-count payments" if existing.exists?
      raise ArgumentError, "Resolve every other payroll run before converting complete history" if company.pay_periods.where.not(id: run_ids).exists?
      raise ArgumentError, "This client already has live YTD balances" if EmployeeYtdTotal.where(employee_id: company.employees.select(:id)).exists? || CompanyYtdTotal.where(company_id: company.id).exists?
      raise ArgumentError, "This year already has an applied opening balance" if HistoricalEmployeeYtdBalance.joins(:historical_ytd_bridge).where(company_id: company.id, tax_year: tax_year, historical_ytd_bridges: { status: "applied" }).exists?
      checks = periods.flat_map { |period| period.fetch("paychecks") }
      raise ArgumentError, "Too many paychecks" if checks.size > SourceAdapter::MAX_PAYCHECKS
      duplicate = periods.flat_map { |period| period.fetch("paychecks").map { |row| [ Integer(row.fetch("employee_id").to_s, 10), period.fetch("pay_date") ] } }.group_by(&:itself).any? { |_key, rows| rows.many? }
      raise ArgumentError, "An employee has duplicate paychecks on the same pay date; reconcile the source into one period" if duplicate
      employees = company.employees.where(id: checks.map { |row| row.fetch("employee_id") }).index_by(&:id)
      periods.each { |period| validate_period!(period, employees) }
      cap = AnnualTaxConfig.historical_ss_wage_base(tax_year)
      raise ArgumentError, "Configure the #{tax_year} Social Security wage base before recording history" unless cap
      checks.group_by { |row| row.fetch("employee_id").to_i }.each do |employee_id, rows|
        total = Amounts.totals(rows)
        ss = total.fetch("social_security_taxable_wages").to_d + total.fetch("social_security_taxable_tips").to_d
        medicare = total.fetch("medicare_taxable_wages").to_d
        unless ss == [ medicare, cap ].min && total.fetch("additional_medicare_taxable_wages").to_d == [ medicare - 200_000, 0.to_d ].max
          raise ArgumentError, "Employee #{employee_id}: source annual FICA bases need reconciliation before normal live payroll can use this history"
        end
      end
    end

    def validate_period!(period, employees)
      start_date = Date.iso8601(period.fetch("start_date").to_s)
      end_date = Date.iso8601(period.fetch("end_date").to_s)
      pay_date = Date.iso8601(period.fetch("pay_date").to_s)
      unless start_date <= end_date && end_date <= pay_date && pay_date < Date.current && pay_date < takeover_on && pay_date.year == tax_year
        raise ArgumentError, "History requires ordered period dates and a past pay date in the tax year before takeover"
      end
      raise ArgumentError, "Each period needs a provider register/page reference" if period["source_reference"].to_s.strip.blank? || period["source_reference"].to_s.length > 500
      rows = period.fetch("paychecks")
      raise ArgumentError, "Each period requires at least one paycheck" unless rows.is_a?(Array) && rows.any?
      if period["run_id"]
        run = company.pay_periods.find_by(id: period["run_id"])
        unless run && run.calculated? && run.regular_cycle? && run.run_purpose == "regular" && !run.parallel_run? && run.correction_status.nil? && run.corrects_pay_period_id.nil?
          raise ArgumentError, "Only calculated, uncommitted, nonparallel regular runs can become history"
        end
        unless [ run.start_date, run.end_date, run.pay_date ] == [ start_date, end_date, pay_date ] && SourceAdapter.digest(run) == period["source_digest"]
          raise ArgumentError, "Run #{run.id} changed; reload the source and reconcile again"
        end
        if run.payroll_items.any? { |item| item.check_number.present? || item.check_prepared_at || item.check_printed_at || item.voided? || item.payroll_reversed_at || item.import_source.present? } ||
            run.non_employee_checks.exists? || run.payroll_liability_postings.exists? || run.loan_transactions.exists? || run.payroll_intake_sessions.exists? || run.time_tracking_imports.exists? || run.aire_payroll_calendar_period || run.payroll_parallel_run_review
          raise ArgumentError, "Run #{run.id} has payment, correction, or connected-source evidence; reconcile it separately"
        end
        unless run.payroll_items.pluck(:employee_id).sort == rows.map { |row| Integer(row.fetch("employee_id").to_s, 10) }.sort
          raise ArgumentError, "Run #{run.id}: keep each source employee exactly once"
        end
      end
      rows.each do |row|
        employee = employees[Integer(row.fetch("employee_id").to_s, 10)]
        raise ArgumentError, "Every paycheck must map to an existing employee of this client" unless employee && employee.employment_type != "contractor"
        identity = payload.fetch("identities", {})[employee.id.to_s].to_h
        if identity["source_name"].to_s.squish.downcase != employee.full_name.squish.downcase || identity["ssn_last4"].to_s != employee.ssn_last_four || employee.ssn_last_four.blank?
          raise ArgumentError, "Verify the provider name and SSN last four for #{employee.full_name} against the existing roster"
        end
        raise ArgumentError, "Paycheck source name must match the verified identity" unless row["source_employee_name"].to_s.squish.downcase == identity["source_name"].to_s.squish.downcase
        raise ArgumentError, "Provider payment references must be at most 255 characters" if row["provider_payment_reference"].to_s.length > 255
        Amounts.validate!(row)
      end
      raise ArgumentError, "Each period requires provider register totals" unless period["register_totals"].is_a?(Hash)
      totals = Amounts.totals(rows)
      Amounts::REGISTER_FIELDS.each do |field|
        expected = Amounts.money(period.fetch("register_totals", {})[field], "Register #{field}")
        unless expected == totals.fetch(field).to_d
          raise ArgumentError, "#{pay_date}: register #{field.humanize.downcase} mismatch (register #{expected.to_s('F')}, paychecks #{totals[field]}). Correct the source amounts before conversion."
        end
      end
    end
  end
end
