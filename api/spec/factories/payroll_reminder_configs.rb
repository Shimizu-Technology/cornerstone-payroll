# frozen_string_literal: true

FactoryBot.define do
  factory :payroll_reminder_config do
    company
    enabled { false }
    recipients { [] }
    days_before_due { 3 }
    send_overdue_alerts { true }
  end
end
