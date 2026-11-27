# frozen_string_literal: true

# Single source of truth for period-aware employee pay-readiness gating,
# narrowed run-purpose exemptions (§6.4), active org-admin overrides, and
# scoped stale-calculation / state-aware payment-delivery checks (§6.3B).
#
# Always evaluates readiness in Ruby via EmployeeReadinessEvaluator (never
# relying on the SQL scope as the final decision maker).
class PayrollReadinessPolicy
  STALE_ERROR_PREFIX = "Recalculate payroll — employee pay, withholding, tax ID, payment method, or status changed after calculation for"

  class << self
    def company_has_gated_employees?(company_id)
      return false if company_id.blank?

      cache = Current.company_gated_employees_cache
      return cache[company_id] if cache&.key?(company_id)

      has_gated = Employee.where(company_id: company_id, readiness_gate_enforced: true).exists?
      cache[company_id] = has_gated if cache
      has_gated
    end

    def clear_company_gated_cache!(company_id = nil)
      cache = Current.company_gated_employees_cache
      return unless cache

      if company_id
        cache.delete(company_id)
      else
        cache.clear
      end
    end

    def fingerprint_scoped?(employee:, pay_period:, client_managed: nil)
      return true if employee.readiness_gate_enforced?

      if client_managed.nil?
        CompanyFeatures.for(pay_period.company).client_managed_employee_lifecycle?
      else
        client_managed
      end
    end

    def readiness_blocker_for(pay_period:, employee:, payroll_item: nil)
      return nil unless employee&.readiness_gate_enforced?
      return nil if readiness_exempt?(pay_period: pay_period, employee: employee, payroll_item: payroll_item)

      result = EmployeeReadinessEvaluator.for_pay_period(employee, pay_period)
      return nil if result.ready?
      return nil if covered_by_override?(pay_period: pay_period, employee: employee, missing_keys: result.missing_keys)

      result
    end

    def blocked_employee_ids_for(pay_period:, employees:)
      candidates = Array(employees).select(&:readiness_gate_enforced?)
      return [] if candidates.empty?

      items_by_employee_id = pay_period.payroll_items
        .where(employee_id: candidates.map(&:id))
        .includes(:correction_for_payroll_item, :financial_correction_origin_item)
        .index_by(&:employee_id)

      candidates.each_with_object([]) do |employee, blocked|
        blocker = readiness_blocker_for(
          pay_period: pay_period,
          employee: employee,
          payroll_item: items_by_employee_id[employee.id]
        )
        blocked << employee.id if blocker.present?
      end
    end

    def readiness_excluded_employees_for(pay_period)
      return [] unless pay_period.status.in?(%w[draft calculated approved]) && !pay_period.voided?
      return [] unless company_has_gated_employees?(pay_period.company_id)

      excluded_ids = pay_period.pay_period_excluded_employees.pluck(:employee_id)
      candidates = Employee.where(company_id: pay_period.company_id, readiness_gate_enforced: true)
        .eligible_for_period(pay_period.start_date, pay_period.end_date)
        .where.not(id: excluded_ids)
        .includes(
          :employee_compensation_changes,
          :employee_wage_rates,
          :employee_wage_rate_versions,
          :employee_w4_elections,
          :employee_status_events,
          :employee_readiness_overrides
        )
        .order(:last_name, :first_name, :id)
        .to_a
      return [] if candidates.empty?

      items_by_employee_id = pay_period.payroll_items
        .where(employee_id: candidates.map(&:id))
        .includes(:correction_for_payroll_item, :financial_correction_origin_item)
        .index_by(&:employee_id)

      candidates.filter_map do |employee|
        blocker = readiness_blocker_for(
          pay_period: pay_period,
          employee: employee,
          payroll_item: items_by_employee_id[employee.id]
        )
        next unless blocker

        {
          employee_id: employee.id,
          name: employee.full_name,
          employment_type: employee.payroll_compensation_on(pay_period.end_date).employment_type,
          reason: blocker.reason,
          missing_keys: blocker.missing_keys,
          missing_labels: blocker.missing_items.filter_map(&:missing_label),
          status: blocker.status
        }
      end
    end

    # Narrowed §6.4 exemptions. Every PayPeriod::RUN_PURPOSES value enforces the
    # readiness gate by default; only the exact named cases below are exempt.
    def readiness_exempt?(pay_period:, employee:, payroll_item: nil)
      case pay_period.run_purpose
      when "correction"
        verified_correction_paycheck?(pay_period: pay_period, employee: employee, payroll_item: payroll_item)
      when "final"
        terminated_on_or_before?(employee, pay_period.end_date)
      when "adjustment"
        late_hours_adjustment_exempt?(pay_period: pay_period, employee: employee) ||
          terminated_with_prior_committed_pay?(pay_period: pay_period, employee: employee)
      else
        false
      end
    end

    # System-generated correction paycheck exemption is per paycheck, not per run:
    # the run must be a system-generated correction AND this paycheck must be
    # linked to a verified source paycheck for the same employee and company.
    def verified_correction_paycheck?(pay_period:, employee:, payroll_item: nil)
      return false unless system_generated_correction_run?(pay_period)

      item = payroll_item || pay_period.payroll_items
        .includes(:correction_for_payroll_item, :financial_correction_origin_item)
        .find_by(employee_id: employee.id)
      return false unless item
      return false unless item.company_id == pay_period.company_id && item.employee_id == employee.id

      if item.correction_for_payroll_item_id.present?
        source_item = item.correction_for_payroll_item
        return verified_supplemental_source_item?(pay_period: pay_period, employee: employee, source_item: source_item)
      end

      if item.financial_correction_origin_item_id.present?
        origin_item = item.financial_correction_origin_item
        return verified_void_redo_origin_item?(pay_period: pay_period, employee: employee, origin_item: origin_item)
      end

      false
    end

    def system_generated_correction_run?(pay_period)
      pay_period.run_purpose == "correction" &&
        (pay_period.run_purpose_source == "system_correction" ||
          pay_period.corrects_pay_period_id.present? ||
          pay_period.correction_status == "correction")
    end

    def covered_by_override?(pay_period:, employee:, missing_keys:)
      overrides = if employee.association(:employee_readiness_overrides).loaded?
        employee.employee_readiness_overrides.select { |ov| ov.revoked_at.nil? && ov.company_id == pay_period.company_id }
      else
        employee.employee_readiness_overrides.active.where(company_id: pay_period.company_id).to_a
      end

      overrides.any? do |override|
        override.active_for_period?(pay_period) && override.covers_missing_keys?(missing_keys)
      end
    end

    # Returns an array of stale items for a pay period:
    #   [{ payroll_item_id:, employee_id:, name:, reason: }]
    # stage: :approve checks fingerprint + item_payment_delivery_method +
    #        employee_payment_default_at_calculation.
    # stage: :commit checks fingerprint + item_payment_delivery_method (ignoring
    #        later employee default changes once item.payment_delivery_method is
    #        materialized).
    def stale_calculation_employees_for(pay_period, stage: nil)
      return [] unless pay_period.status.in?(%w[calculated approved]) && !pay_period.voided?

      resolved_stage = stage || (pay_period.approved? ? :commit : :approve)
      client_managed = CompanyFeatures.for(pay_period.company).client_managed_employee_lifecycle?
      unless client_managed
        return [] unless company_has_gated_employees?(pay_period.company_id) || any_recorded_fingerprint?(pay_period)
      end

      scope = pay_period.payroll_items.financially_reportable
      unless client_managed
        scope = scope.joins(:employee).where(
          "employees.readiness_gate_enforced = TRUE OR payroll_items.calculation_context_snapshot ? 'paycheck_input_fingerprint'"
        )
      end

      items = scope.includes(
        :correction_for_payroll_item,
        :financial_correction_origin_item,
        employee: [
          :employee_compensation_changes,
          :employee_wage_rates,
          :employee_wage_rate_versions,
          :employee_w4_elections,
          { employee_deductions: :deduction_type },
          { employee_payroll_fields: :payroll_field_definition },
          :employee_retirement_elections,
          :employee_retirement_year_inputs
        ]
      ).order(:id).to_a

      items.filter_map do |item|
        employee = item.employee
        next unless employee

        snapshot = item.calculation_context_snapshot.to_h
        recorded_fingerprint = snapshot["paycheck_input_fingerprint"]
        scoped = fingerprint_scoped?(employee: employee, pay_period: pay_period, client_managed: client_managed)
        next unless scoped || recorded_fingerprint.present?
        next if verified_correction_paycheck?(pay_period: pay_period, employee: employee, payroll_item: item)

        reason = staleness_reason(item: item, employee: employee, pay_period: pay_period, snapshot: snapshot, stage: resolved_stage)
        next unless reason

        {
          payroll_item_id: item.id,
          employee_id: employee.id,
          name: employee.full_name,
          reason: reason
        }
      end
    end

    private

    def any_recorded_fingerprint?(pay_period)
      if pay_period.association(:payroll_items).loaded?
        pay_period.payroll_items.any? do |item|
          item.payroll_reversed_at.nil? && item.calculation_context_snapshot.to_h.key?("paycheck_input_fingerprint")
        end
      else
        pay_period.payroll_items.financially_reportable
          .where("calculation_context_snapshot ? 'paycheck_input_fingerprint'")
          .exists?
      end
    end

    def staleness_reason(item:, employee:, pay_period:, snapshot:, stage:)
      recorded_fingerprint = snapshot["paycheck_input_fingerprint"]
      if recorded_fingerprint.blank?
        return "Payroll item was calculated without an input fingerprint and must be recalculated."
      end

      current_fingerprint = PayrollCalculationContext.paycheck_input_fingerprint(employee: employee, pay_period: pay_period)
      if recorded_fingerprint != current_fingerprint
        return "Employee pay, withholding, tax ID, deductions, or status changed after calculation."
      end

      if stale_item_rates?(item: item, employee: employee, pay_period: pay_period)
        return "Payroll item pay rate or wage-rate allocations no longer match current employee rates for this period."
      end

      recorded_item_method = snapshot["item_payment_delivery_method"]
      if recorded_item_method.present? && item.effective_payment_delivery_method != recorded_item_method
        return "Payment delivery method changed after calculation."
      end

      if stage == :approve
        recorded_default = snapshot["employee_payment_default_at_calculation"]
        current_default = employee.payment_delivery_method.presence || "paper_check"
        if recorded_default.present? && current_default != recorded_default
          return "Employee payment delivery default changed after calculation."
        end
      end

      nil
    end

    def stale_item_rates?(item:, employee:, pay_period:)
      return false if item.timekeeping_source == "correction_reference"
      return false if PayrollWageRateInput.source_locked?(item)

      compensation = employee.payroll_compensation_on(pay_period.end_date)
      return true if item.employment_type.present? && item.employment_type != compensation.employment_type

      if compensation.hourly_pay_basis? && item.wage_rate_hours.present?
        dated_rates = employee.wage_rates_on(pay_period.end_date, include_inactive: true)
        rates_by_id = dated_rates.index_by { |rate| rate.id.to_i }
        rates_by_label = dated_rates.index_by { |rate| rate.label.to_s.strip.downcase }

        item.wage_rate_hours.each do |entry|
          rate_id = entry["employee_wage_rate_id"].presence&.to_i
          dated_rate = if rate_id
            rates_by_id[rate_id]
          else
            rates_by_label[entry["label"].to_s.strip.downcase]
          end
          return true if rate_id && dated_rate.nil?
          return true if dated_rate && entry["rate"].to_d != dated_rate.rate.to_d
        end

        primary_entry = item.wage_rate_hours.find { |entry| entry["is_primary"] } || item.wage_rate_hours.first
        expected_rates = [
          primary_entry&.fetch("rate", nil)&.to_d,
          employee.default_payroll_rate_on(pay_period.end_date).to_d
        ].compact.uniq
        return true unless expected_rates.include?(item.pay_rate.to_d)

        false
      else
        expected_rate = employee.default_payroll_rate_on(pay_period.end_date)
        item.pay_rate.to_d != expected_rate.to_d
      end
    end

    def verified_supplemental_source_item?(pay_period:, employee:, source_item:)
      return false unless source_item.present? && pay_period.corrects_pay_period_id.present?
      return false unless source_item.company_id == pay_period.company_id
      return false unless source_item.employee_id == employee.id
      return false unless source_item.pay_period_id == pay_period.corrects_pay_period_id

      source_period = source_item.pay_period
      source_period.present? && source_period.company_id == pay_period.company_id &&
        source_period.committed? && !source_period.voided? && source_item.payroll_reversed_at.nil?
    end

    def verified_void_redo_origin_item?(pay_period:, employee:, origin_item:)
      return false unless origin_item.present? && pay_period.source_pay_period_id.present?
      return false unless origin_item.company_id == pay_period.company_id
      return false unless origin_item.employee_id == employee.id
      return false if origin_item.payroll_reversed_at.present?

      origin_period = origin_item.pay_period
      return false unless origin_period.present? && origin_period.company_id == pay_period.company_id
      return false unless origin_period.committed? || origin_period.voided?

      valid_origin_period_ids(pay_period).include?(origin_item.pay_period_id)
    end

    def valid_origin_period_ids(pay_period)
      prior_committed_corrections = PayPeriodCorrectionEvent.where(
        pay_period_id: pay_period.source_pay_period_id,
        company_id: pay_period.company_id,
        action_type: "correction_run_committed"
      ).pluck(:resulting_pay_period_id)

      ([ pay_period.source_pay_period_id ] + prior_committed_corrections).compact.uniq
    end

    def terminated_on_or_before?(employee, date)
      employee.status == "terminated" && employee.termination_date.present? && employee.termination_date <= date
    end

    def late_hours_adjustment_exempt?(pay_period:, employee:)
      late_hours_run = pay_period.late_hours_run
      return false unless late_hours_run.present? && !late_hours_run.closed?
      return false unless late_hours_run.company_id == pay_period.company_id
      return false if late_hours_run.applied_at.nil?

      origin = late_hours_run.origin_pay_period
      return false unless origin.present? && origin.company_id == pay_period.company_id && origin.committed? && !origin.voided?

      in_selection = Array(late_hours_run.selection_snapshot).any? do |row|
        row.is_a?(Hash) && row["payroll_employee_id"].to_i == employee.id
      end
      return false unless in_selection

      TimeTrackingEntryAllocation.where(
        company_id: pay_period.company_id,
        pay_period_id: pay_period.id,
        employee_id: employee.id
      ).where("total_hours > 0").where(original_work_date: origin.start_date..origin.end_date).exists?
    end

    def terminated_with_prior_committed_pay?(pay_period:, employee:)
      return false unless terminated_on_or_before?(employee, pay_period.end_date)

      PayrollItem.joins(:pay_period)
        .financially_reportable
        .where(
          company_id: pay_period.company_id,
          employee_id: employee.id,
          pay_periods: {
            company_id: pay_period.company_id,
            status: "committed",
            correction_status: [ nil, "correction" ]
          }
        )
        .where.not(pay_period_id: pay_period.id)
        .exists?
    end
  end
end
