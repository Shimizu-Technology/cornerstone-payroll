# frozen_string_literal: true

module EmployeeProfiles
  # §8a: the employee app's next payday comes only from the company's next
  # real regular pay run, and only when its date is settled: a committed
  # run, or a run created on a confirmed pay schedule that sets its own
  # dates (a manual-dates draft's date is tentative). A void+redo correction
  # run stands in for the run it replaced, as in PayPeriod.reportable_periods.
  # If the next run's date isn't settled, there is none rather than a later
  # one. Former employees never get one. Context shows its pay date; My job
  # reads rates on its end date, as payroll does.
  class NextPayday
    OPEN_STATUSES = %w[draft calculated approved committed].freeze

    def self.period(context, today: PayrollBusinessClock.today)
      return if context.former?

      period = PayPeriod.where(company_id: context.company_id, status: OPEN_STATUSES, cycle: "regular",
        run_purpose: "regular", correction_status: [ nil, "correction" ], test_workspace_role: nil, parallel_run: false)
        .where(pay_date: today..)
        .order(pay_date: :asc, id: :asc).first
      return unless period
      return period if period.status == "committed"

      schedule = CompanyPaySchedule.find_by(id: period.company_pay_schedule_id, company_id: period.company_id)
      period if schedule&.confirmed? && !schedule.manual_dates?
    end
  end
end
