# frozen_string_literal: true

# One definition shape for the client library and employee pay-item editors.
class PayrollFieldSerializer
  def self.call(field)
    {
      id: field.id,
      company_id: field.company_id,
      owner_employee_id: field.owner_employee_id,
      name: field.name,
      description: field.description,
      kind: field.kind,
      tax_treatment: field.tax_treatment,
      category: field.category,
      reporting_group: field.reporting_group,
      amount_type: field.amount_type,
      default_amount: field.default_amount&.to_f,
      default_percentage: field.default_percentage&.to_f,
      show_in_payroll_grid: field.show_in_payroll_grid,
      active: field.active,
      sort_order: field.sort_order,
      payee_name: field.payee_name,
      reference_number: field.reference_number,
      active_assignment_count: field.employee_payroll_fields.count(&:active?),
      assigned_employee_count: field.employee_payroll_fields.map(&:employee_id).uniq.length,
      created_at: field.created_at,
      updated_at: field.updated_at
    }
  end
end
