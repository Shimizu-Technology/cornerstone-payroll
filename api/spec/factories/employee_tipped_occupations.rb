# frozen_string_literal: true

FactoryBot.define do
  factory :employee_tipped_occupation do
    employee
    occupation_code { "101" }
    effective_from { Date.new(2026, 1, 1) }
  end
end
