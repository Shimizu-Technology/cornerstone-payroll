# frozen_string_literal: true

FactoryBot.define do
  factory :daily_time_record do
    employee
    company { employee.company }
    employee_work_profile { nil }
    work_date { Date.new(2024, 1, 2) }
    workweek_started_on { work_date.beginning_of_week(:sunday) }
    scheduled_hours { 8 }
    actual_worked_hours { nil }
    pto_hours { 0 }
    holiday_hours { 0 }
    source { "manual" }
    ledger_key { "authoritative" }
  end
end
