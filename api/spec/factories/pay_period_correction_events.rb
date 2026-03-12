# frozen_string_literal: true

FactoryBot.define do
  factory :pay_period_correction_event do
    association :pay_period, :committed
    association :company
    actor { nil }
    action_type { "void_initiated" }
    actor_name { "Test User" }
    reason { "Test reason" }
    financial_snapshot { {} }
    metadata { {} }
  end
end
