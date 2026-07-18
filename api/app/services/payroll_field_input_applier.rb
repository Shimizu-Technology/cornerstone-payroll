# frozen_string_literal: true

class PayrollFieldInputApplier
  MODES = %w[default override].freeze

  def initialize(pay_period:, company_id:)
    @pay_period = pay_period
    @company_id = company_id
  end

  def apply!(payroll_item:, employee:, inputs:)
    normalized_inputs(inputs).each do |field_id, input|
      assignment = assignments_for(employee).find do |candidate|
        candidate.payroll_field_definition_id == field_id
      end
      raise ArgumentError, "Payroll field is not assigned to this employee for this pay date" unless assignment

      field = assignment.payroll_field_definition
      raise ArgumentError, "Payroll field is not available in the payroll worksheet" unless field.active? && field.show_in_payroll_grid?
      raise ArgumentError, "Payroll field belongs to another client" unless field.company_id == company_id
      if direct_loan_field_should_be_skipped?(payroll_item, field)
        raise ArgumentError, "#{field.name} is already supplied by this payroll import's loan deduction"
      end

      entry = payroll_item.payroll_item_field_entries.detect do |candidate|
        candidate.payroll_field_definition_id == field.id
      end
      attributes = snapshot_attributes(assignment, field)

      if input.fetch(:mode) == "default"
        # Percentage defaults are deliberately refreshed by PayrollCalculator
        # after it computes the employee's base gross. This initial amount only
        # establishes the selected source before calculate! runs.
        amount = assignment.effective_amount_for(payroll_item.gross_pay.to_d)
        if entry
          entry.assign_attributes(attributes.merge(amount: amount, source: "employee_default", metadata: (entry.metadata || {}).except("uncapped_amount")))
        else
          payroll_item.payroll_item_field_entries.build(attributes.merge(amount: amount, source: "employee_default"))
        end
      else
        amount = decimal_amount!(input[:amount], field.name)
        if entry
          entry.assign_attributes(attributes.merge(amount: amount, source: "manual", metadata: (entry.metadata || {}).except("uncapped_amount")))
        else
          payroll_item.payroll_item_field_entries.build(attributes.merge(amount: amount, source: "manual"))
        end
      end
    end
  end

  private

  attr_reader :pay_period, :company_id

  def assignments_for(employee)
    @assignments_by_employee ||= {}
    @assignments_by_employee[employee.id] ||= employee.employee_payroll_fields
      .select do |assignment|
        assignment.active? &&
          (assignment.start_date.blank? || assignment.start_date <= pay_period.pay_date) &&
          (assignment.end_date.blank? || assignment.end_date >= pay_period.pay_date)
      end
  end

  def normalized_inputs(inputs)
    raw = if inputs.respond_to?(:to_unsafe_h)
      inputs.to_unsafe_h
    elsif inputs.respond_to?(:to_h)
      inputs.to_h
    else
      {}
    end

    raw.each_with_object({}) do |(field_id, input), result|
      data = input.respond_to?(:to_unsafe_h) ? input.to_unsafe_h : input.to_h
      mode = (data["mode"] || data[:mode]).to_s
      raise ArgumentError, "Payroll field input mode must be default or override" unless mode.in?(MODES)

      result[parsed_field_id!(field_id)] = { mode: mode, amount: data["amount"] || data[:amount] }
    end
  end

  def parsed_field_id!(field_id)
    parsed_id = begin
      Integer(field_id, 10)
    rescue ArgumentError, TypeError
      raise ArgumentError, "Payroll field ID is invalid"
    end

    raise ArgumentError, "Payroll field ID must be positive" unless parsed_id.positive?

    parsed_id
  end

  def decimal_amount!(value, field_name)
    amount = BigDecimal(value.to_s)
    raise ArgumentError, "#{field_name} must be zero or greater" unless amount.finite? && amount >= 0

    amount.round(2)
  rescue ArgumentError, FloatDomainError
    raise ArgumentError, "#{field_name} must be a valid amount"
  end

  def snapshot_attributes(assignment, field)
    {
      payroll_field_definition: field,
      label: field.name,
      kind: field.kind,
      tax_treatment: field.tax_treatment,
      category: field.category,
      reporting_group: field.reporting_group,
      employee_paid: field.employee_paid?,
      employer_paid: field.employer_paid?,
      active: true,
      notes: assignment.notes
    }
  end

  def direct_loan_field_should_be_skipped?(payroll_item, field)
    payroll_item.loan_deduction.to_f.positive? &&
      field.category == "loan" &&
      field.tax_treatment == "post_tax_deduction"
  end
end
