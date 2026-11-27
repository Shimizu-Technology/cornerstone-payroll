# frozen_string_literal: true

module EmployeeProfiles
  # "My job" in the employee app: the person's own job at the open link's
  # company as of today. Pay comes from the same effective-dated history
  # payroll reads (EmployeeCompensationChangeService.snapshot and
  # Employee#wage_rates_on). A change already scheduled to take effect by
  # the end of the period the next payday pays for comes with it, read on
  # that period's end date as payroll reads it, so the note matches the next
  # paycheck. Never the SSN, bank details, notes or anyone else's record. A
  # former job shows nothing.
  class Job
    def initialize(context, today: PayrollBusinessClock.today)
      @context = context
      @today = today
    end

    def as_json
      return if @context.former? || employee.status == "terminated"

      {
        employer_name: @context.company.name.to_s.squish.presence,
        department: employee.department&.name.to_s.squish.presence,
        role: role,
        # The number printed as "Employee ID" on pay stubs (PayStubGenerator).
        employee_id: employee.id.to_s,
        worker_type: employee.contractor? ? "1099" : "w2",
        pay_frequency: snapshot["pay_frequency"],
        pay: pay,
        start_date: start_date&.iso8601,
        # Only when a rehire started a later stint.
        first_hired_on: (employee.hire_date.iso8601 if employee.hire_date && start_date != employee.hire_date),
        # Payroll pays a paper check when no method is set (PayrollItem#effective_payment_delivery_method).
        payment_method: employee.payment_delivery_method.presence || "paper_check",
        # The first Help contact, for "Something wrong? Contact ...".
        contact_name: CompanyHelpContact.where(company_id: @context.company_id).order(:position, :id).pick(:name).to_s.squish.presence
      }
    end

    private

    def employee
      @employee ||= Employee.with_compensation_history.includes(:department, :company_job_role)
        .where(company_id: @context.company_id).find(@context.employee_id)
    end

    def snapshot
      @snapshot ||= EmployeeCompensationChangeService.snapshot(employee, @today)
    end

    # The current stint's start: the latest rehire (a reactivation after a
    # termination) on or after the hire date, else the hire date.
    def start_date
      return @start_date if defined?(@start_date)

      rehired_on = EmployeeStatusEvent.where(company_id: @context.company_id, employee_id: employee.id,
        event_type: "reactivated", previous_status: "terminated").where(effective_date: ..@today).maximum(:effective_date)
      @start_date = [ employee.hire_date, rehired_on ].compact.max
    end

    # The end date of the period the shown next payday pays for, when a
    # scheduled change could reach that paycheck.
    def next_period_end
      return @next_period_end if defined?(@next_period_end)

      end_date = NextPayday.period(@context, today: @today)&.end_date
      @next_period_end = end_date if end_date && end_date > @today
    end

    # The pay version payroll will use for the next paycheck, when it starts after today.
    def upcoming_compensation
      return @upcoming_compensation if defined?(@upcoming_compensation)

      version = employee.compensation_on(next_period_end) if next_period_end
      @upcoming_compensation = version if version && version.effective_on > @today
    end

    # The company's job role (#672) when one is set, else the free-text title.
    def role
      employee.company_job_role&.name.to_s.squish.presence || employee.job_title.to_s.squish.presence
    end

    def pay
      case snapshot["employment_type"]
      when "salary" then with_change(salary(snapshot))
      when "contractor" then snapshot["contractor_pay_type"] == "hourly" ? hourly : with_change(flat_fee(snapshot))
      else hourly
      end
    end

    # Each active wage rate (one per job) with its label, and its scheduled
    # change when there is one. A worker paid from the profile rate alone
    # has one unlabeled rate.
    def hourly
      later = next_period_end ? employee.wage_rates_on(next_period_end).index_by(&:id) : {}
      rates = employee.wage_rates_on(@today).filter_map do |row|
        { label: row.label, rate: money(row.rate), change: wage_rate_change(row, later[row.id]) } if row.rate
      end
      if rates.empty? && snapshot["pay_rate"]
        later_rate = upcoming_compensation&.pay_rate
        change = { rate: money(later_rate), effective_on: upcoming_compensation.effective_on.iso8601 } if later_rate && later_rate.to_d != snapshot["pay_rate"].to_d
        rates = [ { label: nil, rate: money(snapshot["pay_rate"]), change: change } ]
      end
      { type: "hourly", rates: rates }
    end

    def wage_rate_change(row, later)
      return unless later&.rate && later.rate.to_d != row.rate.to_d

      version = employee.wage_rate_version_for(employee.employee_wage_rates.find { |rate| rate.id == row.id }, next_period_end)
      { rate: money(later.rate), effective_on: version.effective_on.iso8601 } if version && version.effective_on > @today
    end

    # A salary or flat fee change on the same pay basis; a change of basis isn't described.
    def with_change(current)
      later = upcoming_compensation&.snapshot
      return current.merge(change: nil) unless later && later.values_at(*%w[employment_type salary_type contractor_pay_type]) ==
        snapshot.values_at(*%w[employment_type salary_type contractor_pay_type])

      upcoming = current[:type] == "salary" ? salary(later) : flat_fee(later)
      changed = upcoming[:per_period] && upcoming[:per_period] != current[:per_period]
      current.merge(change: (upcoming.merge(effective_on: upcoming_compensation.effective_on.iso8601).except(:type) if changed))
    end

    def flat_fee(compensation)
      { type: "flat_fee", per_period: money(compensation["pay_rate"]) }
    end

    # The per-period amount follows SalaryPayrollCalculator: an annual salary
    # is divided by the pay periods in a year. A variable salary has no set amount.
    def salary(compensation)
      rate = compensation["pay_rate"]
      periods = SalaryPayrollCalculator::PERIODS_PER_YEAR[compensation["pay_frequency"]]
      return { type: "salary", per_period: nil, annual: nil } if compensation["salary_type"] == "variable" || rate.nil? || periods.nil?

      rate = rate.to_d
      per_period, annual = compensation["salary_type"] == "per_period" ? [ rate, rate * periods ] : [ rate / periods, rate ]
      { type: "salary", per_period: money(per_period), annual: money(annual) }
    end

    def money(value)
      return nil if value.nil?

      format("%.2f", value.to_d.round(2))
    end
  end
end
