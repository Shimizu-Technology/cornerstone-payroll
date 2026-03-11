# frozen_string_literal: true

FactoryBot.define do
  factory :payroll_item do
    pay_period
    employee
    employment_type { "hourly" }
    pay_rate { 15.00 }
    hours_worked { 80 }
    overtime_hours { 0 }
    holiday_hours { 0 }
    pto_hours { 0 }
    reported_tips { 0 }
    bonus { 0 }
    gross_pay { 0 }
    net_pay { 0 }
    withholding_tax { 0 }
    social_security_tax { 0 }
    medicare_tax { 0 }

    trait :with_overtime do
      overtime_hours { 10 }
    end

    trait :with_tips do
      reported_tips { 200.00 }
    end

    trait :salary do
      employment_type { "salary" }
      pay_rate { 52_000.00 }
      hours_worked { 0 }
    end

    trait :with_check do
      sequence(:check_number) { |n| (1000 + n).to_s }
      gross_pay { 1200.00 }
      net_pay    { 960.00 }
      withholding_tax { 120.00 }
      social_security_tax { 74.40 }
      medicare_tax { 17.40 }
      total_deductions { 211.80 }
      check_print_count { 0 }
      voided { false }
    end

    trait :printed do
      with_check
      check_printed_at { Time.current }
      check_print_count { 1 }
    end

    trait :voided do
      with_check
      voided { true }
      voided_at { Time.current }
      void_reason { "Test void — physical check destroyed" }
    end
  end
end
