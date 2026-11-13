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

      previous = @employee.payroll_items.financially_reportable
        .joins(:pay_period).merge(PayPeriod.committed)
        .where(company_id: @pay_period.company_id)
        .where("pay_periods.pay_date < ?", @pay_period.pay_date)
        .order("pay_periods.pay_date DESC, pay_periods.committed_at DESC, payroll_items.id DESC").first
      entries = Array(previous&.wage_rate_hours).select do |entry|
        %w[regular_hours overtime_hours holiday_hours pto_hours].any? { |key| entry[key].to_d.positive? }
      end
      selected = if entries.one?
        entry = entries.first
        rates.find do |rate|
          entry["employee_wage_rate_id"].present? ? rate.id.to_s == entry["employee_wage_rate_id"].to_s :
            rate.label == entry["label"] && rate.rate == entry["rate"].to_d
        end
      end
      # A legacy single-rate paycheck has an implicit allocation at pay_rate.
      if selected.nil? && previous && previous.wage_rate_hours.empty? && previous.hours_worked.to_d.positive?
        matches = rates.select { |rate| rate.rate == previous.pay_rate }
        selected = matches.first if matches.one?
      end
      {
        wage_rate_options: rates.map { |rate| { id: rate.id, label: rate.label, rate: rate.rate.to_f } },
        selected_wage_rate_id: selected&.id,
        wage_rate_default_source: selected ? "Last committed payroll, paid #{previous.pay_period.pay_date.iso8601}" :
          "Choose a job and rate — the last committed payroll does not identify one active job.",
        wage_rate_default_pay_period_id: selected ? previous.pay_period_id : nil
      }
    end
  end
end
