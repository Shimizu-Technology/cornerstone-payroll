# frozen_string_literal: true

module PayrollImport
  # Revel supplies hours but no usable job. Never infer a split across jobs.
  class WageRateChoice
    def initialize(employee:, pay_period:)
      @employee = employee
      @pay_period = pay_period
    end

    def preview
      rates = @employee.active_wage_rates.to_a
      return {} unless @employee.hourly_pay_basis? && rates.map(&:rate).uniq.many?

      history = PayPeriod.committed
      if @pay_period.company.test_workspace?
        baselines = PayPeriod.where(status: "approved", test_workspace_role: "baseline")
          .where.not(test_workspace_source_pay_period_id: nil)
        history = history.or(baselines)
      end
      previous = @employee.payroll_items.financially_reportable
        .joins(:pay_period).merge(history)
        .where(company_id: @pay_period.company_id)
        .where("pay_periods.pay_date < ?", @pay_period.pay_date)
        .order("pay_periods.pay_date DESC, pay_periods.committed_at DESC, payroll_items.id DESC").first
      entries = Array(previous&.wage_rate_hours).select do |entry|
        %w[regular_hours overtime_hours holiday_hours pto_hours].any? { |key| entry[key].to_d.nonzero? }
      end
      jobs = entries.group_by { |entry| entry["employee_wage_rate_id"].presence || [ entry["label"], entry["rate"].to_d ] }
      selected = if jobs.one?
        entry = entries.first
        if previous.pay_period.training_baseline?
          # Copied immutable allocations retain source job IDs. Resolve only
          # one identical active label/rate in this employee's copied setup.
          matches = rates.select { |rate| rate.label == entry["label"] && rate.rate == entry["rate"].to_d }
          matches.first if matches.one?
        else
          rates.find do |rate|
            entry["employee_wage_rate_id"].present? ? rate.id.to_s == entry["employee_wage_rate_id"].to_s :
              rate.label == entry["label"] && rate.rate == entry["rate"].to_d
          end
        end
      end
      # A legacy single-rate paycheck has an implicit allocation at pay_rate.
      if selected.nil? && previous && previous.wage_rate_hours.empty? && previous.hours_worked.to_d.positive?
        matches = rates.select { |rate| rate.rate == previous.pay_rate }
        selected = matches.first if matches.one?
      end
      history_label = previous&.pay_period&.training_baseline? ? "Copied locked payroll" : "Last committed payroll"
      {
        wage_rate_options: rates.map { |rate| { id: rate.id, label: rate.label, rate: rate.rate.to_f } },
        selected_wage_rate_id: selected&.id,
        wage_rate_default_source: selected ? "#{history_label}, paid #{previous.pay_period.pay_date.iso8601}" :
          "Choose a job and rate — the last committed payroll does not identify one active job.",
        wage_rate_default_pay_period_id: selected ? previous.pay_period_id : nil
      }
    end
  end
end
