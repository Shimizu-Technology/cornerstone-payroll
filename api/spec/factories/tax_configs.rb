# frozen_string_literal: true

FactoryBot.define do
  factory :annual_tax_config do
    # Use high year numbers to avoid conflicts with seeded data (2026)
    sequence(:tax_year) { |n| 2100 + n }
    ss_wage_base { 160_200 }
    ss_rate { 0.062 }
    medicare_rate { 0.0145 }
    additional_medicare_rate { 0.009 }
    additional_medicare_threshold { 200_000 }
    is_active { false }
  end

  factory :filing_status_config do
    association :annual_tax_config
    filing_status { "single" }
    standard_deduction { 14_600 }

    trait :single do
      filing_status { "single" }
      standard_deduction { 14_600 }
    end

    trait :married do
      filing_status { "married" }
      standard_deduction { 29_200 }
    end

    trait :head_of_household do
      filing_status { "head_of_household" }
      standard_deduction { 21_900 }
    end
  end

  factory :tax_bracket do
    association :filing_status_config
    sequence(:bracket_order) { |n| n }
    min_income { 0 }
    max_income { 11_600 }
    rate { 0.10 }
  end

  factory :tax_config_audit_log do
    association :annual_tax_config
    action { "created" }
    new_value { "Tax year created" }
  end
end
