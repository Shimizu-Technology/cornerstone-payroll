# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    company
    organization { company.organization }
    sequence(:email) { |n| "user#{n}@example.com" }
    sequence(:name) { |n| "User #{n}" }
    role { "admin" }
    active { true }

    trait :with_client_assignment do
      after(:create) do |user|
        next unless user.client? && user.company.present?
        next if user.company_assignments.exists?(company_id: user.company_id)

        CompanyAssignment.create!(user: user, company: user.company)
      end
    end
  end
end
