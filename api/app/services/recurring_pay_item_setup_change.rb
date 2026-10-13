# frozen_string_literal: true

# Captures the source of an open payroll calculation before a setup mutation.
# Call under the company lock, then lock periods before changing any loan rows.
# The saved worksheet is retained; a changed source requires explicit calculation
# and approval again rather than silently finalizing the previous numbers.
class RecurringPayItemSetupChange
  FIELD_KEYS = %w[id name description kind tax_treatment category reporting_group amount_type default_amount default_percentage active payee_name reference_number].freeze
  ASSIGNMENT_KEYS = %w[id employee_id payroll_field_definition_id amount percentage active start_date end_date notes employee_loan_id].freeze

  def initialize(company:, employee_ids: nil)
    @company = company
    @employee_ids = employee_ids
    scope = company.pay_periods.without_training_baselines.where(status: %w[calculated approved])
    scope = scope.where(id: PayrollItem.where(employee_id: employee_ids).select(:pay_period_id)) if employee_ids
    @periods = scope.order(:id).lock.to_a
    @items = PayrollItem.where(pay_period_id: @periods.map(&:id)).includes(:payroll_item_field_entries).to_a.group_by(&:pay_period_id)
    @before = capture_setup
  end

  def invalidate_changed!
    after = capture_setup
    @periods.filter_map do |period|
      next if effective_setup(period, @before) == effective_setup(period, after)

      period.invalidate_calculation!(reason: "Recurring pay item setup changed. Refresh setup and recalculate payroll before approval or finalizing.")
      period.id
    end
  end

  private

  def capture_setup
    assignments = EmployeePayrollField.joins(:employee).where(employees: { company_id: @company.id })
    assignments = assignments.where(employee_id: @employee_ids) if @employee_ids
    employees = Employee.where(company_id: @company.id)
    employees = employees.where(id: @employee_ids) if @employee_ids
    {
      fields: PayrollFieldDefinition.where(company_id: @company.id).index_by(&:id),
      assignments: assignments.to_a.group_by(&:employee_id),
      legacy: employees.to_h { |employee| [ employee.id, { adjustments: employee.default_payroll_adjustments, earnings: employee.default_custom_earnings } ] }
    }
  end

  def effective_setup(period, setup)
    Array(@items[period.id]).sort_by(&:id).map do |item|
      recurring = if period.recurring_items_enabled?
        Array(setup[:assignments][item.employee_id]).filter_map do |assignment|
          field = setup[:fields][assignment.payroll_field_definition_id]
          next unless assignment.active? && field&.active?
          next if assignment.start_date && assignment.start_date > period.pay_date
          next if assignment.end_date && assignment.end_date < period.pay_date

          definition = field.attributes.slice(*FIELD_KEYS)
          if field.amount_type == "percentage"
            definition.delete("default_amount")
            definition.delete("default_percentage") unless assignment.percentage.nil?
          else
            definition.delete("default_percentage")
            definition.delete("default_amount") unless assignment.amount.nil?
          end
          [ assignment.attributes.slice(*ASSIGNMENT_KEYS), definition ]
        end.sort_by { |row| row.first.fetch("id") }
      else
        []
      end
      # Explicit worksheet entries are intentionally retained on recalculation,
      # but a shared definition edit still makes its reviewed metadata stale.
      explicit_definitions = item.payroll_item_field_entries.select { |entry| entry.active? && entry.source.in?(%w[manual import]) }
        .sort_by(&:id).map { |entry| setup[:fields][entry.payroll_field_definition_id]&.attributes&.slice(*FIELD_KEYS) }
      legacy = setup[:legacy][item.employee_id] || {}
      [ item.id, recurring, explicit_definitions,
        period.recurring_items_enabled? && !item.payroll_adjustments_overridden? && item.payroll_adjustments_default_snapshot? ? legacy[:adjustments] : nil,
        period.recurring_items_enabled? && !item.custom_earnings_overridden? && (item.custom_columns_data || {})[PayrollItem::CUSTOM_EARNINGS_SOURCE_KEY] == PayrollItem::EMPLOYEE_DEFAULT_ADJUSTMENTS_SOURCE ? legacy[:earnings] : nil ]
    end
  end
end
