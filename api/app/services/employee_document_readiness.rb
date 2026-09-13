# frozen_string_literal: true

class EmployeeDocumentReadiness
  class BlockedError < StandardError; end

  DEFAULT_REQUIREMENTS = {
    "w2" => %w[identity_and_work_authorization withholding_election],
    "1099" => %w[contractor_tax_form]
  }.freeze

  # The explicit employee flag lets this gate fail closed for new hires without
  # retroactively blocking legacy and QuickBooks-cutover rosters at deployment.
  def self.seed_new_hire!(employee:, actor:)
    employee.update!(document_readiness_required: true) unless employee.document_readiness_required?
    DEFAULT_REQUIREMENTS.fetch(employee.tax_classification).each do |requirement_type|
      employee.employee_document_requirements.create_or_find_by!(requirement_type: requirement_type) do |requirement|
        requirement.company = employee.company
        requirement.created_by = actor
        requirement.label = EmployeeDocumentRequirement::REQUIREMENT_TYPES.fetch(requirement_type)
        requirement.status = "missing"
        requirement.required_for_payroll = true
        requirement.due_on = employee.hire_date
      end
    end
  end

  def self.require_payroll_ready!(pay_period)
    employee_ids = pay_period.payroll_items.not_voided.select(:employee_id)
    employees = Employee.where(
      company_id: pay_period.company_id,
      id: employee_ids,
      document_readiness_required: true
    ).order(:last_name, :first_name, :id).to_a
    return if employees.empty?

    gaps = gaps_for(employees: employees)
    return if gaps.empty?

    details = gaps.map { |gap| "#{gap.fetch(:employee_name)}: #{gap.fetch(:label)} (#{gap.fetch(:status).tr('_', ' ')})" }

    raise BlockedError,
      "Resolve required new-hire documents before approving or committing payroll: #{details.join('; ')}."
  end

  def self.gap_count(employees:)
    gaps_for(employees: employees).size
  end

  def self.gaps_for(employees:)
    employee_rows = employees.to_a
    return [] if employee_rows.empty?

    employee_ids = employee_rows.map(&:id)
    requirements = EmployeeDocumentRequirement.required_for_payroll
      .where(company_id: employee_rows.first.company_id, employee_id: employee_ids)
      .includes(:employee)
      .order("employees.last_name", "employees.first_name", :requirement_type)
      .references(:employee)
      .to_a
    requirements_by_employee = requirements.group_by(&:employee_id)
    gaps = requirements.reject(&:satisfied?).map do |requirement|
      {
        employee_name: requirement.employee.full_name,
        label: requirement.label,
        status: requirement.status
      }
    end
    employee_rows.each do |employee|
      present_types = Array(requirements_by_employee[employee.id]).map(&:requirement_type)
      (DEFAULT_REQUIREMENTS.fetch(employee.tax_classification) - present_types).each do |requirement_type|
        gaps << {
          employee_name: employee.full_name,
          label: EmployeeDocumentRequirement::REQUIREMENT_TYPES.fetch(requirement_type),
          status: "checklist_missing"
        }
      end
    end
    gaps
  end

  def self.summary(employee)
    requirements = employee.employee_document_requirements.to_a
    required = requirements.select(&:required_for_payroll?)
    expected_types = employee.document_readiness_required? ? DEFAULT_REQUIREMENTS.fetch(employee.tax_classification) : []
    missing_types = expected_types - required.map(&:requirement_type)
    {
      total: requirements.size,
      required: required.size + missing_types.size,
      satisfied: required.count(&:satisfied?),
      ready_for_payroll: missing_types.empty? && required.all?(&:satisfied?)
    }
  end
end
