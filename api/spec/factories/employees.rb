# frozen_string_literal: true

FactoryBot.define do
  factory :employee do
    company
    department
    first_name { Faker::Name.first_name }
    last_name { Faker::Name.last_name }
    employment_type { "hourly" }
    pay_rate { 15.00 }
    pay_frequency { "biweekly" }
    status { "active" }
    filing_status { "single" }
    allowances { 0 }
    additional_withholding { 0 }
    retirement_rate { 0 }
    roth_retirement_rate { 0 }
    hire_date { Date.new(2024, 1, 1) }

    trait :hourly do
      employment_type { "hourly" }
      pay_rate { 15.00 }
    end

    trait :salary do
      employment_type { "salary" }
      pay_rate { 52_000.00 } # Annual salary
    end

    trait :with_retirement do
      retirement_rate { 0.04 }
    end

    trait :with_roth do
      roth_retirement_rate { 0.03 }
    end

    trait :married do
      filing_status { "married" }
    end

    trait :head_of_household do
      filing_status { "head_of_household" }
    end
  end
end
