# frozen_string_literal: true

require "bigdecimal"

module PayrollIntake
  # Shared helper for applying (and clearing) portal client changes
  # (`owner_pay` period pay and `extra_hours` job allocations) plus their
  # provenance (`period_pay_evidence`, `client_change_evidence`) across both
  # `PayrollImport::ImportService` (MoSa / reviewed-hours) and
  # `PayrollIntake::ApplyService` (universal workbook).
  class ClientChangeApplier
    def initialize(pay_period:)
      @pay_period = pay_period
    end

    def apply_period_pay!(payroll_item, employee, row)
      amount = decimal_or_zero(row[:period_pay])
      if amount.zero?
        evidence = payroll_item.custom_columns_data.to_h["period_pay_evidence"].to_h
        if %w[mosa_change_workbook client_submission].include?(evidence["source_type"])
          payroll_item.salary_override = nil
          payroll_item.clear_imported_period_pay_evidence!
        end
        return
      end

      raise ArgumentError, "Pay this employee must be a positive amount." unless amount.positive?
      raise ArgumentError, "Pay this employee is only allowed for variable-pay salary employees." unless employee.payroll_compensation_on(pay_period.end_date).variable_salary?

      evidence = row[:period_pay_evidence].to_h.deep_symbolize_keys
      raise ArgumentError, "Pay this employee must confirm THIS EMPLOYEE ONLY." unless evidence[:scope] == "THIS EMPLOYEE ONLY"
      raise ArgumentError, "Pay this employee requires a source or reason." if evidence[:source].to_s.strip.blank?
      unless iso_date(evidence[:effective_pay_date]) == pay_period.pay_date
        raise ArgumentError, "Pay this employee must use this payroll's pay date."
      end

      payroll_item.salary_override = amount
      data = payroll_item.custom_columns_data.is_a?(Hash) ? payroll_item.custom_columns_data.deep_dup : {}
      data["period_pay_evidence"] = evidence.deep_stringify_keys.merge(
        "amount" => amount.to_s("F"),
        "employee_id" => employee.id,
        "employee_name" => employee.full_name,
        "source_type" => evidence[:source_type] == "client_submission" ? "client_submission" : "mosa_change_workbook"
      )
      payroll_item.custom_columns_data = data
    end

    def apply_client_hours!(payroll_item, employee, row, use_selected_wage_rate_for_existing: false)
      input = row.fetch(:client_extra_hours).to_h.deep_symbolize_keys
      period_rates = employee.wage_rates_on(pay_period.end_date)
      rate = period_rates.find { |candidate| candidate.id.to_s == input[:employee_wage_rate_id].to_s }
      unless rate && rate.rate == input[:rate].to_d
        raise ArgumentError, "Saved job and rate changed for #{employee.full_name}. Review the client change again."
      end

      restore_client_hours_baseline!(payroll_item) if row[:workbook_only]
      baseline_regular_hours = payroll_item.hours_worked.to_d.to_s("F")
      baseline_overtime_hours = payroll_item.overtime_hours.to_d.to_s("F")
      baseline_allocations = payroll_item.wage_rate_hours.deep_dup
      allocations = payroll_item.wage_rate_hours.deep_dup

      resolved = resolve_client_hours_deltas!(payroll_item, employee, row, input, rate)
      delta_regular = resolved.fetch(:delta_regular_hours)
      delta_overtime = resolved.fetch(:delta_overtime_hours)

      if allocations.empty? && [ payroll_item.hours_worked, payroll_item.overtime_hours, payroll_item.holiday_hours, payroll_item.pto_hours ].any? { |hours| hours.to_d.positive? }
        base = if use_selected_wage_rate_for_existing && row[:selected_wage_rate_id].present?
          period_rates.find { |candidate| candidate.id.to_s == row[:selected_wage_rate_id].to_s }
        else
          primary = employee.primary_wage_rate_on(pay_period.end_date)
          primary if primary && primary.rate == payroll_item.pay_rate && period_rates.map(&:rate).uniq.one?
        end
        unless base
          raise ArgumentError, "Choose a saved job for the existing hours for #{employee.full_name}."
        end

        allocations << {
          "employee_wage_rate_id" => base.id,
          "label" => base.label,
          "rate" => base.rate.to_f,
          "regular_hours" => payroll_item.hours_worked.to_f,
          "overtime_hours" => payroll_item.overtime_hours.to_f,
          "holiday_hours" => payroll_item.holiday_hours.to_f,
          "pto_hours" => payroll_item.pto_hours.to_f,
          "active" => true,
          "is_primary" => base.is_primary
        }
      end

      entry = allocations.find { |allocation| allocation["employee_wage_rate_id"].to_s == rate.id.to_s && allocation["rate"].to_d == rate.rate }
      unless entry
        entry = {
          "employee_wage_rate_id" => rate.id,
          "label" => rate.label,
          "rate" => rate.rate.to_f,
          "regular_hours" => 0,
          "overtime_hours" => 0,
          "holiday_hours" => 0,
          "pto_hours" => 0,
          "is_primary" => rate.is_primary,
          "active" => true
        }
        allocations << entry
      end

      entry["regular_hours"] = (entry["regular_hours"].to_d + delta_regular).to_f
      entry["overtime_hours"] = (entry["overtime_hours"].to_d + delta_overtime).to_f
      payroll_item.hours_worked = payroll_item.hours_worked.to_d + delta_regular
      payroll_item.overtime_hours = payroll_item.overtime_hours.to_d + delta_overtime
      payroll_item.wage_rate_hours = allocations

      if row[:client_change_evidence].present?
        row[:client_change_evidence] = row[:client_change_evidence].merge(
          hours_mode: resolved[:hours_mode],
          workweek: resolved[:workweek],
          workweek_start_date: input[:workweek_start_date] || resolved[:workweek_start_date],
          workweek_end_date: input[:workweek_end_date] || resolved[:workweek_end_date],
          delta_regular_hours: delta_regular.to_s("F"),
          delta_overtime_hours: delta_overtime.to_s("F"),
          gross_pay_delta: format("%.2f", resolved[:gross_pay_delta]),
          baseline_regular_hours: baseline_regular_hours,
          baseline_overtime_hours: baseline_overtime_hours,
          baseline_allocations: baseline_allocations,
          applied_regular_hours: payroll_item.hours_worked.to_d.to_s("F"),
          applied_overtime_hours: payroll_item.overtime_hours.to_d.to_s("F"),
          applied_allocations: payroll_item.wage_rate_hours,
          applied_hours: client_hours_inputs(payroll_item)
        ).compact
      end
    end

    def sync_client_change_evidence!(payroll_item, row)
      data = payroll_item.custom_columns_data.is_a?(Hash) ? payroll_item.custom_columns_data.deep_dup : {}
      evidence = row&.dig(:client_change_evidence)
      data["client_change_evidence"] = evidence.present? ? evidence.deep_stringify_keys : nil
      payroll_item.custom_columns_data = data
    end

    def restore_client_hours_baseline!(item)
      previous = item.custom_columns_data.to_h["client_change_evidence"].to_h
      return unless previous["kind"] == "extra_hours"

      overtime_matches = !previous.key?("applied_overtime_hours") ||
        item.overtime_hours.to_d == previous["applied_overtime_hours"].to_d
      unless previous.key?("baseline_regular_hours") &&
          item.hours_worked.to_d == previous["applied_regular_hours"].to_d &&
          overtime_matches &&
          same_job_hours?(item.wage_rate_hours, previous["applied_allocations"]) &&
          client_hours_inputs(item) == previous["applied_hours"]
        raise ArgumentError, "Saved hours changed after the client's hours were imported for #{item.employee.full_name}. Applied regular hours: #{previous["applied_regular_hours"]}; baseline: #{previous["baseline_regular_hours"]}; current: #{item.hours_worked}. Save the intended hours against each job on the worksheet, then reopen this import. Reconcile the worksheet hours before importing again."
      end
      item.hours_worked = previous.fetch("baseline_regular_hours")
      item.overtime_hours = previous["baseline_overtime_hours"] if previous.key?("baseline_overtime_hours")
      item.wage_rate_hours = previous.fetch("baseline_allocations")
      true
    end

    private

    attr_reader :pay_period

    def resolve_client_hours_deltas!(payroll_item, employee, row, input, rate)
      if ExtraHoursPolicy.contractor?(employee, as_of: pay_period.end_date)
        return ExtraHoursPolicy.resolve_deltas!(
          mode: "straight_time",
          baseline_regular: payroll_item.hours_worked,
          baseline_overtime: payroll_item.overtime_hours,
          rate: rate.rate,
          hours: input[:hours],
          regular_hours: input[:regular_hours],
          overtime_hours: input[:overtime_hours]
        )
      end

      if input[:workweek].present?
        workweeks = ExtraHoursPolicy.workweeks_for(
          company: pay_period.company,
          start_date: pay_period.start_date,
          end_date: pay_period.end_date,
          pay_period: pay_period
        )
        base_w1 = input.key?(:baseline_week1_hours) ? input[:baseline_week1_hours] : row[:week1_hours]
        base_w2 = input.key?(:baseline_week2_hours) ? input[:baseline_week2_hours] : row[:week2_hours]
        return ExtraHoursPolicy.resolve_deltas!(
          mode: "workweek",
          baseline_regular: payroll_item.hours_worked,
          baseline_overtime: payroll_item.overtime_hours,
          rate: rate.rate,
          hours: input[:hours],
          workweek: input[:workweek],
          workweeks: workweeks,
          baseline_week1: base_w1,
          baseline_week2: base_w2
        )
      end

      if input.key?(:regular_hours) || input.key?(:overtime_hours)
        return ExtraHoursPolicy.resolve_deltas!(
          mode: "split",
          baseline_regular: payroll_item.hours_worked,
          baseline_overtime: payroll_item.overtime_hours,
          rate: rate.rate,
          regular_hours: input[:regular_hours],
          overtime_hours: input[:overtime_hours]
        )
      end

      raise ArgumentError, "Choose regular/overtime hours or a workweek for #{employee.full_name}'s extra hours before applying."
    end

    def client_hours_inputs(item)
      %w[hours_worked overtime_hours holiday_hours pto_hours].to_h { |field| [ field, item.public_send(field).to_d.to_s("F") ] }
    end

    def same_job_hours?(current, applied)
      applied_jobs = job_hours(applied)
      job_hours(current) == applied_jobs || (current.blank? && applied_jobs.size <= 1)
    end

    def job_hours(entries)
      Array(entries).map(&:to_h).group_by { |entry| [ entry["employee_wage_rate_id"].to_s, entry["rate"].to_d ] }
        .transform_values { |list| %w[regular_hours overtime_hours holiday_hours pto_hours].map { |field| list.sum { |entry| entry[field].to_d } } }
        .reject { |_job, hours| hours.all?(&:zero?) }
    end

    def decimal_or_zero(value)
      BigDecimal(value.to_s, exception: false)&.round(2) || 0.to_d
    end

    def iso_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
  end
end
