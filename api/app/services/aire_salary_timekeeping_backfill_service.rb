# frozen_string_literal: true

class AireSalaryTimekeepingBackfillService
  class Error < StandardError; end

  MONEY_COLUMNS = %w[
    gross_pay net_pay withholding_tax social_security_tax medicare_tax
    employer_social_security_tax employer_medicare_tax total_deductions
  ].freeze

  def self.call!(company_id:, employee_id:, expected_employee_name:, effective_on:, actor:, apply: false)
    new(
      company_id:,
      employee_id:,
      expected_employee_name:,
      effective_on:,
      actor:,
      apply:
    ).call!
  end

  def initialize(company_id:, employee_id:, expected_employee_name:, effective_on:, actor:, apply:)
    @company = Company.find(company_id)
    @employee = @company.employees.find(employee_id)
    @expected_employee_name = expected_employee_name.to_s.squish
    @effective_on = Date.parse(effective_on.to_s)
    @actor = actor
    @apply = ActiveModel::Type::Boolean.new.cast(apply)
  rescue ActiveRecord::RecordNotFound
    raise Error, "The explicit company and employee IDs did not resolve to the same worker"
  rescue Date::Error
    raise Error, "A valid confirmed effective date is required"
  end

  def call!
    validate_target!
    items = eligible_items
    preview = {
      apply: @apply,
      company_id: @company.id,
      employee_id: @employee.id,
      employee_name: @employee.full_name,
      effective_on: @effective_on,
      payroll_item_ids: items.ids,
      payroll_item_count: items.count,
      committed_payroll_item_count: items.joins(:pay_period).where(pay_periods: { status: "committed" }).count,
      changes_money: false
    }
    return preview unless @apply

    ApplicationRecord.transaction do
      profile = ensure_profile!
      items.find_each do |item|
        before_money = item.attributes.slice(*MONEY_COLUMNS)
        PayrollTimeAllocationService.call!(payroll_item: item, generated_source: "production_backfill")
        item.save!
        item.reload
        raise Error, "Backfill attempted to change payroll dollars for item ##{item.id}" unless item.attributes.slice(*MONEY_COLUMNS) == before_money
      end
      preview.merge(employee_work_profile_id: profile.id, daily_time_record_count: @employee.daily_time_records.current.count)
    end
  end

  private

  def validate_target!
    raise Error, "Expected employee name must exactly match #{@employee.full_name.inspect}" unless @employee.full_name == @expected_employee_name
    raise Error, "The selected worker must be a W-2 salary employee" unless @employee.salary? && @employee.w2_employee?
    unless @actor&.organization_admin? || @actor&.manager?
      raise Error, "A manager or organization admin must authorize the backfill"
    end

    existing = @employee.employee_work_profiles.find_by(ends_on: nil)
    return unless existing && !matching_profile?(existing)

    raise Error, "A different current work profile already exists; review it manually instead of overwriting it"
  end

  def eligible_items
    @employee.payroll_items
      .joins(:pay_period)
      .where(
        pay_periods: {
          status: "committed",
          correction_status: [ nil, "correction" ],
          run_purpose: %w[regular correction],
          includes_base_salary: true
        }
      )
      .where("pay_periods.end_date >= ?", @effective_on)
      .order("pay_periods.start_date ASC")
  end

  def ensure_profile!
    existing = @employee.employee_work_profiles.find_by(ends_on: nil)
    return existing if existing

    EmployeeWorkProfileChangeService.call!(
      employee: @employee,
      actor: @actor,
      attributes: {
        effective_on: @effective_on,
        pay_basis: "salary",
        overtime_status: "needs_review",
        exemption_category: nil,
        exemption_reason: nil,
        standard_weekly_hours: 40,
        daily_schedule: standard_schedule,
        timekeeping_mode: "schedule_with_exceptions",
        source: "production_migration",
        notes: "Employer confirmed a 40-hour standard schedule. Overtime exemption still requires a separate duties-test review. Payroll dollars were not recalculated."
      }
    )
  end

  def matching_profile?(profile)
    profile.pay_basis == "salary" && profile.overtime_status == "needs_review" && profile.standard_weekly_hours.to_d == 40 &&
      profile.timekeeping_mode == "schedule_with_exceptions" && profile.daily_schedule == standard_schedule
  end

  def standard_schedule
    {
      "sunday" => 0,
      "monday" => 8,
      "tuesday" => 8,
      "wednesday" => 8,
      "thursday" => 8,
      "friday" => 8,
      "saturday" => 0
    }
  end
end
