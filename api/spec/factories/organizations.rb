# frozen_string_literal: true

FactoryBot.define do
  factory :organization do
    sequence(:name) { |n| "Test Organization #{n}" }
    sequence(:slug) { |n| "test-organization-#{n}" }
    status { "active" }
  end
end
