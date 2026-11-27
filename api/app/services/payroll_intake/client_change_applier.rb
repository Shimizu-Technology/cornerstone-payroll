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
      inputs = Array(row[:client_extra_hours_list].presence || [ row[:client_extra_hours] ].compact)
        .map { |item| item.to_h.deep_symbolize_keys }
      raise ArgumentError, "Missing extra-hours input for #{employee.full_name}." if inputs.empty?

      period_rates = employee.wage_rates_on(pay_period.end_date)
      resolved_rates = inputs.map do |input|
        rate = period_rates.find { |candidate| candidate.id.to_s == input[:employee_wage_rate_id].to_s }
        unless rate && rate.rate == input[:rate].to_d
          raise ArgumentError, "Saved job and rate changed for #{employee.full_name}. Review the client change again."
        end
        rate
      end

      restore_client_hours_baseline!(payroll_item) if row[:workbook_only]
      baseline_regular_hours = payroll_item.hours_worked.to_d.to_s("F")
      baseline_overtime_hours = payroll_item.overtime_hours.to_d.to_s("F")
      baseline_allocations = payroll_item.wage_rate_hours.deep_dup
      allocations = payroll_item.wage_rate_hours.deep_dup

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

      running_regular = payroll_item.hours_worked.to_d
      running_overtime = payroll_item.overtime_hours.to_d
      first_input = inputs.first
      running_w1 = first_input.key?(:baseline_week1_hours) ? first_input[:baseline_week1_hours].to_d : row[:week1_hours].to_d
      running_w2 = first_input.key?(:baseline_week2_hours) ? first_input[:baseline_week2_hours].to_d : row[:week2_hours].to_d

      total_delta_regular = 0.to_d
      total_delta_overtime = 0.to_d
      total_gross_delta = 0.to_d
      applied_entries = []
      last_resolved = nil

      inputs.each_with_index do |input, idx|
        rate = resolved_rates[idx]
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

        resolved = resolve_client_hours_deltas!(
          running_regular,
          running_overtime,
          employee,
          input,
          rate,
          baseline_week1: running_w1,
          baseline_week2: running_w2,
          line_baseline_regular: entry["regular_hours"].to_d,
          line_baseline_overtime: entry["overtime_hours"].to_d
        )
        delta_regular = resolved.fetch(:delta_regular_hours)
        delta_overtime = resolved.fetch(:delta_overtime_hours)

        entry["regular_hours"] = (entry["regular_hours"].to_d + delta_regular).to_f
        entry["overtime_hours"] = (entry["overtime_hours"].to_d + delta_overtime).to_f
        running_regular = (running_regular + delta_regular).round(2)
        running_overtime = (running_overtime + delta_overtime).round(2)
        if resolved[:hours_mode] == "workweek"
          running_w1 = resolved.fetch(:new_week1_hours)
          running_w2 = resolved.fetch(:new_week2_hours)
        end

        total_delta_regular = (total_delta_regular + delta_regular).round(2)
        total_delta_overtime = (total_delta_overtime + delta_overtime).round(2)
        total_gross_delta = (total_gross_delta + resolved[:gross_pay_delta]).round(2)
        last_resolved = resolved
        applied_entries << {
          employee_wage_rate_id: rate.id,
          hours_mode: resolved[:hours_mode],
          workweek: resolved[:workweek],
          workweek_start_date: input[:workweek_start_date] || resolved[:workweek_start_date],
          workweek_end_date: input[:workweek_end_date] || resolved[:workweek_end_date],
          delta_regular_hours: delta_regular.to_s("F"),
          delta_overtime_hours: delta_overtime.to_s("F"),
          gross_pay_delta: format("%.2f", resolved[:gross_pay_delta])
        }.compact
      end

      payroll_item.hours_worked = running_regular
      payroll_item.overtime_hours = running_overtime
      payroll_item.wage_rate_hours = allocations

      if row[:client_change_evidence].present?
        evidence_patch = {
          hours_mode: last_resolved[:hours_mode],
          delta_regular_hours: total_delta_regular.to_s("F"),
          delta_overtime_hours: total_delta_overtime.to_s("F"),
          gross_pay_delta: format("%.2f", total_gross_delta),
          baseline_regular_hours: baseline_regular_hours,
          baseline_overtime_hours: baseline_overtime_hours,
          baseline_allocations: baseline_allocations,
          applied_regular_hours: payroll_item.hours_worked.to_d.to_s("F"),
          applied_overtime_hours: payroll_item.overtime_hours.to_d.to_s("F"),
          applied_allocations: payroll_item.wage_rate_hours,
          applied_hours: client_hours_inputs(payroll_item)
        }
        if applied_entries.one?
          evidence_patch.merge!(
            workweek: last_resolved[:workweek],
            workweek_start_date: first_input[:workweek_start_date] || last_resolved[:workweek_start_date],
            workweek_end_date: first_input[:workweek_end_date] || last_resolved[:workweek_end_date]
          )
        else
          evidence_patch[:entries] = applied_entries
        end
        row[:client_change_evidence] = row[:client_change_evidence].merge(evidence_patch).compact
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
        overtime_detail = if !overtime_matches
          " Applied overtime hours: #{previous["applied_overtime_hours"]}; baseline: #{previous["baseline_overtime_hours"]}; current: #{item.overtime_hours}."
        else
          ""
        end
        raise ArgumentError, "Saved hours changed after the client's hours were imported for #{item.employee.full_name}. Applied regular hours: #{previous["applied_regular_hours"]}; baseline: #{previous["baseline_regular_hours"]}; current: #{item.hours_worked}.#{overtime_detail} Save the intended hours against each job on the worksheet, then reopen this import. Reconcile the worksheet hours before importing again."
      end
      item.hours_worked = previous.fetch("baseline_regular_hours")
      item.overtime_hours = previous["baseline_overtime_hours"] if previous.key?("baseline_overtime_hours")
      item.wage_rate_hours = previous.fetch("baseline_allocations")
      true
    end

    private

    attr_reader :pay_period

    def resolve_client_hours_deltas!(baseline_regular, baseline_overtime, employee, input, rate, baseline_week1:, baseline_week2:, line_baseline_regular:, line_baseline_overtime:)
      if ExtraHoursPolicy.contractor?(employee, as_of: pay_period.end_date)
        return ExtraHoursPolicy.resolve_deltas!(
          mode: "straight_time",
          baseline_regular: baseline_regular,
          baseline_overtime: baseline_overtime,
          line_baseline_regular: line_baseline_regular,
          line_baseline_overtime: line_baseline_overtime,
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
        return ExtraHoursPolicy.resolve_deltas!(
          mode: "workweek",
          baseline_regular: baseline_regular,
          baseline_overtime: baseline_overtime,
          line_baseline_regular: line_baseline_regular,
          line_baseline_overtime: line_baseline_overtime,
          rate: rate.rate,
          hours: input[:hours],
          workweek: input[:workweek],
          workweeks: workweeks,
          baseline_week1: baseline_week1,
          baseline_week2: baseline_week2
        )
      end

      if input.key?(:regular_hours) || input.key?(:overtime_hours)
        return ExtraHoursPolicy.resolve_deltas!(
          mode: "split",
          baseline_regular: baseline_regular,
          baseline_overtime: baseline_overtime,
          line_baseline_regular: line_baseline_regular,
          line_baseline_overtime: line_baseline_overtime,
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
