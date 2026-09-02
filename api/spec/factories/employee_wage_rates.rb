# frozen_string_literal: true

FactoryBot.define do
  factory :employee_wage_rate do
    employee
    sequence(:label) { |n| "Wage rate #{n}" }
    rate { 25 }
    is_primary { false }
    active { true }
  end
end
