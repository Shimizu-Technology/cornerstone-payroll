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
  end
end
