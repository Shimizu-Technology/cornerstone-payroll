# frozen_string_literal: true

module EmployeeProfiles
  # "My job" in the employee app: the person's own job at the open link's
  # company as of today. Pay comes from the same effective-dated history
  # payroll reads (EmployeeCompensationChangeService.snapshot and
  # Employee#wage_rates_on), so it matches the next paycheck's rates. Never
  # the SSN, bank details, notes or anyone else's record. A former job
  # shows nothing.
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
        start_date: employee.hire_date&.iso8601,
        payment_method: employee.payment_delivery_method,
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

    # The company's job role (#672) when one is set, else the free-text title.
    def role
      employee.company_job_role&.name.to_s.squish.presence || employee.job_title.to_s.squish.presence
    end

    def pay
      rate = snapshot["pay_rate"]
      case snapshot["employment_type"]
      when "salary" then salary(rate)
      when "contractor" then snapshot["contractor_pay_type"] == "hourly" ? hourly(rate) : { type: "flat_fee", per_period: money(rate) }
      else hourly(rate)
      end
    end

    # Each active wage rate (one per job) with its label. A worker paid from
    # the profile rate alone has one unlabeled rate.
    def hourly(fallback)
      rates = employee.wage_rates_on(@today).filter_map { |row| { label: row.label, rate: money(row.rate) } if row.rate }
      rates = [ { label: nil, rate: money(fallback) } ] if rates.empty? && fallback
      { type: "hourly", rates: rates }
    end

    # The per-period amount follows SalaryPayrollCalculator: an annual salary
    # is divided by the pay periods in a year. A variable salary has no set amount.
    def salary(rate)
      periods = SalaryPayrollCalculator::PERIODS_PER_YEAR[snapshot["pay_frequency"]]
      return { type: "salary", per_period: nil, annual: nil } if snapshot["salary_type"] == "variable" || rate.nil? || periods.nil?

      rate = rate.to_d
      per_period, annual = snapshot["salary_type"] == "per_period" ? [ rate, rate * periods ] : [ rate / periods, rate ]
      { type: "salary", per_period: money(per_period), annual: money(annual) }
    end

    def money(value)
      return nil if value.nil?

      format("%.2f", value.to_d.round(2))
    end
  end
end
