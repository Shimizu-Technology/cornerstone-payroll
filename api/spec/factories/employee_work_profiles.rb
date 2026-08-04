# frozen_string_literal: true

FactoryBot.define do
  factory :employee_work_profile do
    employee
    company { employee.company }
    confirmed_by { association :user, company: employee.company, organization: employee.company.organization }
    effective_on { employee.hire_date || Date.new(2024, 1, 1) }
    pay_basis { employee.employment_type }
    overtime_status { employee.salary? ? "exempt" : "nonexempt" }
    exemption_category { employee.salary? ? "administrative" : nil }
    exemption_reason { employee.salary? ? "Confirmed exempt administrative duties test" : nil }
    standard_weekly_hours { employee.salary? ? 40 : nil }
    daily_schedule do
      employee.salary? ? {
        "sunday" => 0,
        "monday" => 8,
        "tuesday" => 8,
        "wednesday" => 8,
        "thursday" => 8,
        "friday" => 8,
        "saturday" => 0
      } : {}
    end
    timekeeping_mode { employee.salary? ? "schedule_with_exceptions" : "manual" }
    source { "operator_confirmed" }
    confirmation_status { "confirmed" }
    confirmed_at { Time.current }
  end
end
