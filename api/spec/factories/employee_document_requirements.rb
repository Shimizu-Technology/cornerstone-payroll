# frozen_string_literal: true

FactoryBot.define do
  factory :employee_document_requirement do
    employee
    company { employee.company }
    created_by { association :user, company: company }
    requirement_type { "withholding_election" }
    label { EmployeeDocumentRequirement::REQUIREMENT_TYPES.fetch(requirement_type) }
    status { "missing" }
    required_for_payroll { true }
    due_on { employee.hire_date }
  end
end
