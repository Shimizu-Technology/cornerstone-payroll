# frozen_string_literal: true

FactoryBot.define do
  factory :employee_note do
    association :employee
    company { employee.company }
    association :created_by, factory: :user
    body { "Roke said her start date was Nov 15; the W-4 says Nov 16." }

    trait :hidden do
      hidden_at { Time.current }
      association :hidden_by, factory: :user
      hidden_reason { "Superseded by confirmed hire date from signed W-4." }
    end
  end
end
