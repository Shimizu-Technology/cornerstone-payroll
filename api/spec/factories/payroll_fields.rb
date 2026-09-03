# frozen_string_literal: true

FactoryBot.define do
  factory :payroll_field_definition do
    company
    sequence(:name) { |number| "Payroll Field #{number}" }
    kind { "addition" }
    tax_treatment { "taxable_addition" }
    category { "other" }
    amount_type { "fixed" }
    show_in_payroll_grid { true }
  end

  factory :payroll_item_field_entry do
    payroll_item
    payroll_field_definition
    label { payroll_field_definition.name }
    kind { payroll_field_definition.kind }
    tax_treatment { payroll_field_definition.tax_treatment }
    category { payroll_field_definition.category }
    amount { 10.00 }
    source { "employee_default" }
  end
end
