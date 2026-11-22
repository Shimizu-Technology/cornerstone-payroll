# frozen_string_literal: true

module PayrollImport
  # Revel supplies hours but no usable job. Never infer a split across jobs.
  #
  # An hourly worker with several active jobs gets the job used on the last
  # committed payroll, even when every job pays the same rate: reports show
  # earnings by job label. When history names no single job, equal rates fall
  # back to the primary job (pay is the same) with a notice; different rates
  # need a reviewed choice.
  class WageRateChoice
    def initialize(employee:, pay_period:)
      @employee = employee
      @pay_period = pay_period
    end

    def preview
      # Jobs and the profile rate as they stand on the pay period end date (M3-4).
      rates = @employee.wage_rates_on(@pay_period.end_date)
      return {} unless @employee.payroll_compensation_on(@pay_period.end_date).hourly_pay_basis? && rates.many?

      same_rate = rates.map(&:rate).uniq.one?
      # Without allocations, calculation pays the profile rate. A job choice
      # must not change pay, so a profile rate that differs keeps that path.
      return {} if same_rate && rates.first.rate != @employee.payroll_rate_on(@pay_period.end_date).to_d

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
      fallback = same_rate && selected.nil? ? (rates.find(&:is_primary) || rates.min_by(&:id)) : nil
      default_source = if selected
        "#{history_label}, paid #{previous.pay_period.pay_date.iso8601}"
      elsif fallback
        reason = jobs.many? ? "split hours across jobs" : "doesn't show one job"
        "Primary job (#{fallback.label}). The last committed payroll #{reason}. Every job pays the same rate; change the job if these hours belong to another."
      else
        "Choose a job and rate — the last committed payroll does not identify one active job."
      end
      {
        wage_rate_options: rates.map { |rate| { id: rate.id, label: rate.label, rate: rate.rate.to_f } },
        selected_wage_rate_id: (selected || fallback)&.id,
        wage_rate_default_source: default_source,
        wage_rate_default_pay_period_id: selected ? previous.pay_period_id : nil,
        # Non-blocking: staff may want the department job instead.
        wage_rate_needs_review: fallback.present?
      }
    end
  end
end
