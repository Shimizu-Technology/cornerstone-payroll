# frozen_string_literal: true

# Read-only defaults for the worksheet and calculation requests without an
# explicit selection. Imported hourly rows do not mean the initial regular
# roster has been selected. Once calculated, retain that roster even when a
# setup/import change invalidates the calculation and returns it to draft.
class PayPeriodDefaultRoster
  def initialize(pay_period)
    @pay_period = pay_period
  end

  def employee_ids(additional_employee_ids: [])
    saved_ids = @pay_period.payroll_items.pluck(:employee_id)
    ids = if initial_regular_run?
      eligible = @pay_period.company.employees.eligible_for_period(@pay_period.start_date, @pay_period.end_date)
      if @pay_period.payroll_items.where.not(import_source: [ nil, "" ]).exists?
        types = [ "contractor" ]
        types << "salary" if @pay_period.includes_base_salary?
        saved_ids + eligible.where(employment_type: types).pluck(:id)
      else
        eligible = eligible.where.not(employment_type: "salary") unless @pay_period.includes_base_salary?
        saved_ids + eligible.pluck(:id)
      end
    else
      saved_ids
    end

    additional_employee_ids = [] if @pay_period.correction_run?
    (ids + additional_employee_ids).map(&:to_i).uniq - @pay_period.pay_period_excluded_employees.pluck(:employee_id)
  end

  private

  def initial_regular_run?
    @pay_period.draft? && @pay_period.regular_run? && @pay_period.regular_cycle? &&
      !@pay_period.correction_run? && @pay_period.calculated_at.nil? &&
      !@pay_period.payroll_review_packages.exists?
  end
end
