# frozen_string_literal: true

FactoryBot.define do
  factory :check_event do
    payroll_item { association :payroll_item, :with_check }
    user
    event_type { "printed" }
    check_number { payroll_item.check_number }
    reason { nil }
    ip_address { "127.0.0.1" }
  end
end
