# frozen_string_literal: true

class PayrollFieldInputBuilder
  def initialize(pay_period:, company_id:)
    @pay_period = pay_period
    @company_id = company_id
  end

  def call
    assignments = EmployeePayrollField
      .active
      .effective_on(pay_period.pay_date)
      .joins(:employee, :payroll_field_definition)
      .where(employees: { company_id: company_id, status: "active" })
      .where(payroll_field_definitions: {
        company_id: company_id,
        active: true,
        show_in_payroll_grid: true
      })
      .includes(:employee, :payroll_field_definition)
      .to_a

    saved_field_ids = PayrollItemFieldEntry
      .active
      .joins(:payroll_item)
      .where(payroll_items: { pay_period_id: pay_period.id, company_id: company_id })
      .where.not(payroll_field_definition_id: nil)
      .distinct
      .pluck(:payroll_field_definition_id)

    fields = PayrollFieldDefinition
      .where(company_id: company_id, show_in_payroll_grid: true)
      .where(id: assignments.map(&:payroll_field_definition_id) | saved_field_ids)
      .sort_by { |field| [ field.sort_order, field.name.downcase ] }
    entries = PayrollItemFieldEntry
      .joins(:payroll_item)
      .includes(:payroll_item)
      .where(payroll_items: { pay_period_id: pay_period.id, company_id: company_id })
      .where(payroll_field_definition_id: fields.map(&:id))
      .index_by { |entry| [ entry.payroll_item.employee_id, entry.payroll_field_definition_id ] }
    items = pay_period.payroll_items.where(company_id: company_id).index_by(&:employee_id)

    {
      fields: fields.map { |field| field_payload(field) },
      assignments: assignments.map do |assignment|
        assignment_payload(
          assignment,
          items[assignment.employee_id],
          entries[[ assignment.employee_id, assignment.payroll_field_definition_id ]]
        )
      end
    }
  end

  private

  attr_reader :pay_period, :company_id

  def field_payload(field)
    {
      id: field.id,
      company_id: field.company_id,
      name: field.name,
      description: field.description,
      kind: field.kind,
      tax_treatment: field.tax_treatment,
      category: field.category,
      reporting_group: field.reporting_group,
      amount_type: field.amount_type,
      default_amount: decimal(field.default_amount),
      default_percentage: decimal(field.default_percentage),
      show_in_payroll_grid: field.show_in_payroll_grid,
      active: field.active,
      sort_order: field.sort_order,
      payee_name: field.payee_name,
      reference_number: field.reference_number
    }
  end

  def assignment_payload(assignment, payroll_item, entry)
    field = assignment.payroll_field_definition
    skipped_reason = direct_loan_skip_reason(payroll_item, field)
    suggested_amount = if entry&.active?
      entry.amount
    elsif field.amount_type == "percentage"
      nil
    else
      assignment.amount.presence || field.default_amount || 0
    end

    {
      employee_id: assignment.employee_id,
      payroll_field_definition_id: field.id,
      amount_type: field.amount_type,
      assigned_amount: decimal(assignment.amount),
      assigned_percentage: decimal(assignment.percentage),
      default_amount: decimal(field.default_amount),
      default_percentage: decimal(field.default_percentage),
      suggested_amount: decimal(suggested_amount),
      current_amount: decimal(entry&.amount),
      current_source: entry&.source,
      overridden: entry&.source.in?(%w[manual import]),
      editable: skipped_reason.nil?,
      skipped_reason: skipped_reason
    }
  end

  def direct_loan_skip_reason(payroll_item, field)
    return unless payroll_item&.loan_deduction.to_f.positive?
    return unless field.category == "loan" && field.tax_treatment == "post_tax_deduction"

    "Already supplied by this payroll import's loan deduction"
  end

  def decimal(value)
    value.nil? ? nil : value.to_d.round(2).to_f
  end
end
