# frozen_string_literal: true

FactoryBot.define do
  factory :audit_log do
    action { "records#updated" }
    record_type { "records" }
    event_category { "activity" }
    metadata { {} }
  end
end
