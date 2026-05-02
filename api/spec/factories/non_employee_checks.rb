# frozen_string_literal: true

FactoryBot.define do
  factory :non_employee_check do
    company
    payable_to { "Guam Department of Revenue and Taxation" }
    amount { 125.50 }
    check_type { "grt" }
    check_number { nil }
    payment_period_type { "month" }
    tax_year { 2026 }
    tax_month { 5 }
    payment_date { Date.new(2026, 5, 2) }

    trait :with_check_number do
      sequence(:check_number) { |n| (5000 + n).to_s }
    end

    trait :standalone do
      pay_period { nil }
    end
  end
end
