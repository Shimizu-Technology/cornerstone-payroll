# frozen_string_literal: true

# Captures the mutable employee configuration that influenced a payroll
# calculation. Committed payroll items use this immutable snapshot when a
# later corrective paycheck is recomputed, so profile edits cannot rewrite
# history.
class PayrollCalculationContext
  VERSION = 1

  SCALAR_ATTRIBUTES = %w[
    employment_type
    salary_type
    pay_frequency
    filing_status
    allowances
    w4_form_version
    w4_effective_on
    w4_step2_multiple_jobs
    w4_dependent_credit
    w4_step4a_other_income
    w4_step4b_deductions
    additional_withholding
    retirement_rate
    roth_retirement_rate
    employer_retirement_match_rate
    employer_roth_match_rate
    contractor_pay_type
  ].freeze

  REQUIRED_FOR_CORRECTION = %w[
    employment_type
    salary_type
    pay_frequency
    filing_status
    allowances
    w4_form_version
    w4_step2_multiple_jobs
    w4_dependent_credit
    w4_step4a_other_income
    w4_step4b_deductions
    additional_withholding
    retirement_rate
    roth_retirement_rate
    employer_retirement_match_rate
    employer_roth_match_rate
  ].freeze

  class << self
    def capture(employee:, employee_deductions:, payroll_field_assignments:)
      {
        "version" => VERSION,
        "employee" => employee_snapshot(employee),
        "employee_deductions" => deduction_snapshots(employee_deductions),
        "payroll_field_assignments" => payroll_field_snapshots(payroll_field_assignments)
      }
    end

    def valid_for_correction?(snapshot)
      data = snapshot.to_h.deep_stringify_keys
      employee_data = data["employee"].to_h

      data["version"].to_i == VERSION &&
        REQUIRED_FOR_CORRECTION.all? { |key| employee_data.key?(key) } &&
        data["employee_deductions"].is_a?(Array) &&
        data["payroll_field_assignments"].is_a?(Array)
    end

    def employee_value(snapshot, attribute)
      snapshot.to_h.deep_stringify_keys.dig("employee", attribute.to_s)
    end

    def employee_deductions(snapshot)
      Array(snapshot.to_h.deep_stringify_keys["employee_deductions"]).map do |entry|
        type_data = entry.fetch("deduction_type")
        deduction_type = DeductionType.new(type_data.except("id"))
        deduction_type.id = type_data["id"]

        EmployeeDeduction.new(
          amount: entry["amount"],
          is_percentage: entry["is_percentage"],
          active: true,
          deduction_type: deduction_type
        )
      end
    end

    def payroll_field_assignments(snapshot)
      Array(snapshot.to_h.deep_stringify_keys["payroll_field_assignments"]).map do |entry|
        definition_data = entry.fetch("definition")
        definition = PayrollFieldDefinition.new(definition_data.except("id"))
        definition.id = definition_data["id"]

        EmployeePayrollField.new(
          amount: entry["amount"],
          percentage: entry["percentage"],
          active: true,
          start_date: entry["start_date"],
          end_date: entry["end_date"],
          notes: entry["notes"],
          payroll_field_definition: definition
        )
      end
    end

    private

    def employee_snapshot(employee)
      SCALAR_ATTRIBUTES.index_with do |attribute|
        value = employee.public_send(attribute)
        value.respond_to?(:iso8601) ? value.iso8601 : value
      end
    end

    def deduction_snapshots(deductions)
      deductions.map do |deduction|
        deduction_type = deduction.deduction_type
        {
          "amount" => deduction.amount.to_f,
          "is_percentage" => deduction.is_percentage?,
          "deduction_type" => {
            "id" => deduction_type.id,
            "company_id" => deduction_type.company_id,
            "name" => deduction_type.name,
            "category" => deduction_type.category,
            "sub_category" => deduction_type.sub_category,
            "reporting_group" => deduction_type.reporting_group,
            "active" => deduction_type.active,
            "generates_check" => deduction_type.generates_check
          }
        }
      end
    end

    def payroll_field_snapshots(assignments)
      assignments.map do |assignment|
        definition = assignment.payroll_field_definition
        {
          "amount" => assignment.amount&.to_f,
          "percentage" => assignment.percentage&.to_f,
          "start_date" => assignment.start_date&.iso8601,
          "end_date" => assignment.end_date&.iso8601,
          "notes" => assignment.notes,
          "definition" => {
            "id" => definition.id,
            "company_id" => definition.company_id,
            "name" => definition.name,
            "kind" => definition.kind,
            "tax_treatment" => definition.tax_treatment,
            "category" => definition.category,
            "amount_type" => definition.amount_type,
            "default_amount" => definition.default_amount&.to_f,
            "default_percentage" => definition.default_percentage&.to_f,
            "reporting_group" => definition.reporting_group,
            "active" => definition.active,
            "show_in_payroll_grid" => definition.show_in_payroll_grid
          }
        }
      end
    end
  end
end
