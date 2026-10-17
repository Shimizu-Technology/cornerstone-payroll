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
    newly_seeded = !employee.document_readiness_required?
    employee.update!(document_readiness_required: true) if newly_seeded
    if newly_seeded && employee.intake_exception.present?
      AuditLog.record!(user: actor, company_id: employee.company_id, action: "employee_intake_exception#create",
        record_type: "employees", record_id: employee.id,
        metadata: employee.intake_exception.slice("reason", "authorized_by_id", "deferred_fields", "follow_up_owner_id", "follow_up_due_on"))
    end
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
    items = pay_period.payroll_items.not_voided.includes(:employee).to_a
    stale_setup = items.select do |item|
      employee = item.employee
      next false if employee.intake_exception.blank? || employee.intake_payroll_confirmed_at.blank?
      recorded = item.calculation_context_snapshot.to_h["intake_setup_fingerprint"]
      recorded.blank? || recorded != PayrollCalculationContext.intake_setup_fingerprint(employee: employee)
    end
    if stale_setup.any?
      raise BlockedError, "Recalculate payroll after employee intake setup changed for: #{stale_setup.map(&:employee_full_name).join(', ')}."
    end
    stale_withholding = items.select do |item|
      employee = item.employee
      next false if employee.intake_exception.blank? || employee.contractor?
      election = employee.w4_election_on(pay_period.pay_date)
      election && (item.tax_rule_snapshot || {}).dig("w4", "election_id") != election.id
    end
    if stale_withholding.any?
      raise BlockedError, "Recalculate payroll after confirming or changing withholding setup for: #{stale_withholding.map(&:employee_full_name).join(', ')}."
    end
    incomplete = Employee.where(company_id: pay_period.company_id, id: employee_ids).to_a.reject do |employee|
      EmployeeIntakePolicy.payroll_ready?(employee, pay_period.end_date)
    end
    if incomplete.any?
      raise BlockedError, "Confirm payroll setup and the eligible date before approving or committing payroll: #{incomplete.map(&:full_name).join(', ')}."
    end
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
