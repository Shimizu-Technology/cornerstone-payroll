# frozen_string_literal: true

FactoryBot.define do
  factory :time_tracking_source do
    company
    sequence(:name) { |n| "Time Tracking Source #{n}" }
    source_type { "custom" }
    base_url { "https://time.example.com" }
    shared_secret { "test-shared-secret" }
    active { true }
  end
end
