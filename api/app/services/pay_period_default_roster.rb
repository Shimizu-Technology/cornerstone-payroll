# frozen_string_literal: true

# Read-only defaults for the worksheet and calculation requests without an
# explicit selection. Imported hourly rows do not mean the initial regular
# roster has been selected. Once calculated, retain that roster even when a
# setup/import change invalidates the calculation and returns it to draft.
class PayPeriodDefaultRoster
  def initialize(pay_period)
    @pay_period = pay_period
  end

  def employee_ids(additional_employee_ids: [], excluded_employee_ids: nil)
    saved_ids = @pay_period.payroll_items.pluck(:employee_id)
    ids = if initial_regular_run?
      eligible = @pay_period.company.employees.eligible_for_period(@pay_period.start_date, @pay_period.end_date)
      if @pay_period.payroll_items.where.not(import_source: [ nil, "" ]).exists?
        types = [ "contractor" ]
        types << "salary" if @pay_period.includes_base_salary?
        saved_ids + employee_ids_for_types(eligible, types)
      else
        saved_ids + (@pay_period.includes_base_salary? ? eligible.ids : employee_ids_for_types(eligible, %w[hourly contractor]))
      end
    else
      saved_ids
    end

    additional_employee_ids = [] if @pay_period.correction_run?
    candidate_ids = (ids + additional_employee_ids).map(&:to_i).uniq - (excluded_employee_ids || @pay_period.pay_period_excluded_employees.pluck(:employee_id))
    return candidate_ids if candidate_ids.empty?

    saved_id_set = saved_ids.to_set
    enforced_unsaved = @pay_period.company.employees
      .where(id: candidate_ids - saved_ids, readiness_gate_enforced: true)
      .includes(
        :employee_compensation_changes,
        :employee_wage_rates,
        :employee_wage_rate_versions,
        :employee_w4_elections,
        :employee_status_events,
        :employee_readiness_overrides
      ).to_a
    return candidate_ids if enforced_unsaved.empty?

    blocked_ids = PayrollReadinessPolicy.blocked_employee_ids_for(pay_period: @pay_period, employees: enforced_unsaved)
    candidate_ids - blocked_ids.reject { |id| saved_id_set.include?(id) }
  end

  private

  def employee_ids_for_types(eligible, types)
    eligible.preload(:employee_compensation_changes).filter_map do |employee|
      employee.id if employee.payroll_compensation_on(@pay_period.end_date).employment_type.in?(types)
    end
  end

  def initial_regular_run?
    @pay_period.draft? && @pay_period.regular_run? && @pay_period.regular_cycle? &&
      !@pay_period.correction_run? && @pay_period.calculated_at.nil? &&
      !@pay_period.payroll_review_packages.exists?
  end
end
