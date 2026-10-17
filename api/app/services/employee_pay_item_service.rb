# frozen_string_literal: true

class EmployeePayItemService
  class InvalidSetup < StandardError; end

  ASSIGNMENT_KEYS = %w[amount percentage active start_date end_date notes].freeze
  FIELD_KEYS = %w[name description kind tax_treatment category reporting_group amount_type default_amount default_percentage payee_name reference_number active].freeze
  SCOPE_KEYS = %w[company_id owner_employee_id scope].freeze

  def initialize(employee:)
    @employee = employee
  end

  def create_and_assign(scope:, field_attributes:, assignment_attributes:)
    raise InvalidSetup, "Choose only this employee or a reusable client field" unless scope.in?(%w[employee_only client_wide])

    reject_scope_change!(field_attributes)
    reject_assignment_identity!(assignment_attributes)
    field_attrs = field_attributes.to_h.stringify_keys.slice(*FIELD_KEYS)
    assignment_attrs = validated_assignment_attributes(assignment_attributes)
    if (field_attrs.key?("active") && !ActiveModel::Type::Boolean.new.cast(field_attrs["active"])) ||
       (assignment_attrs.key?("active") && !ActiveModel::Type::Boolean.new.cast(assignment_attrs["active"]))
      raise InvalidSetup, "New pay items must be active when created"
    end
    owner_id = scope == "employee_only" ? @employee.id : nil
    field = assignment = nil
    created = false

    PayrollFieldDefinition.transaction do
      # Existing definition/assignment unique identities plus the company lock
      # serialize double submits without a new idempotency table. A conflicting
      # same-name request must never overwrite another employee's shared setup.
      @employee.company.lock!
      field = PayrollFieldDefinition.find_by(company_id: @employee.company_id, owner_employee_id: owner_id, name: field_attrs["name"])
      if field
        assignment = @employee.employee_payroll_fields.find_by(payroll_field_definition: field)
        candidate_field = PayrollFieldDefinition.new(field_attrs)
        candidate_field.valid?
        candidate_assignment = EmployeePayrollField.new(assignment_attrs.merge(active: true))
        same_field = field_attrs.keys.all? { |key| field.public_send(key) == candidate_field.public_send(key) }
        same_assignment = assignment && (assignment_attrs.keys + [ "active" ]).uniq.all? { |key| assignment.public_send(key) == candidate_assignment.public_send(key) }
        unless same_field && same_assignment && field.active?
          raise InvalidSetup, "A field with this name already exists. Use the existing field or choose a different name."
        end
      else
        field = PayrollFieldDefinition.create!(field_attrs.merge(company_id: @employee.company_id, owner_employee_id: owner_id, show_in_payroll_grid: true, active: true))
        assignment = @employee.employee_payroll_fields.create!(assignment_attrs.merge(payroll_field_definition: field, active: true))
        created = true
      end
    end
    [ field, assignment, created ]
  end

  def update(assignment:, assignment_attributes:, field_attributes: nil)
    reject_assignment_identity!(assignment_attributes)
    reject_scope_change!(field_attributes) if field_attributes
    attrs = validated_assignment_attributes(assignment_attributes)
    field = nil
    field_attrs = field_attributes&.to_h&.stringify_keys&.slice(*FIELD_KEYS)

    EmployeePayrollField.transaction do
      @employee.company.lock!
      assignment.reload
      assignment.employee_loan&.lock!
      assignment.lock!
      field = assignment.payroll_field_definition
      field.lock!
      if field_attrs.present? && field.owner_employee_id != @employee.id
        raise InvalidSetup, "Edit reusable field settings in the client payroll field library"
      end
      if assignment.employee_loan_id.present?
        candidate_assignment = assignment.dup
        candidate_assignment.assign_attributes(attrs)
        if field_attrs.present? || %w[amount percentage].any? { |key| attrs.key?(key) && assignment.public_send(key) != candidate_assignment.public_send(key) }
          raise InvalidSetup, "Edit the tracked loan in Loans; only its repayment dates, notes and active status can be changed here"
        end
      end
      field.update!(field_attrs) if field_attrs.present?
      assignment.update!(attrs)
    end
    [ field, assignment ]
  end

  private

  def reject_scope_change!(attributes)
    if attributes.to_h.stringify_keys.keys.intersect?(SCOPE_KEYS)
      raise InvalidSetup, "A payroll field's client and employee scope cannot be changed"
    end
  end

  def reject_assignment_identity!(attributes)
    if attributes.to_h.stringify_keys.keys.intersect?(%w[id employee_id payroll_field_definition_id employee_loan_id])
      raise InvalidSetup, "A pay item's employee, field and loan link cannot be replaced"
    end
  end

  def validated_assignment_attributes(attributes)
    attrs = attributes.to_h.stringify_keys.slice(*ASSIGNMENT_KEYS)
    %w[start_date end_date].each do |key|
      next if attrs[key].blank?

      Date.iso8601(attrs[key].to_s)
    rescue Date::Error
      raise InvalidSetup, "#{key.humanize} must be a valid payday"
    end
    attrs
  end
end
