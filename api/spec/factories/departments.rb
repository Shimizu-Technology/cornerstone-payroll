# frozen_string_literal: true

FactoryBot.define do
  factory :department do
    company
    sequence(:name) { |n| "Department #{n}" }
    active { true }
  end
end
