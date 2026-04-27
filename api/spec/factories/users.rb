# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    company
    sequence(:email) { |n| "user#{n}@example.com" }
    sequence(:name) { |n| "User #{n}" }
    role { "admin" }
    active { true }
  end
end
