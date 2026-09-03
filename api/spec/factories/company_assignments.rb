# frozen_string_literal: true

FactoryBot.define do
  factory :company_assignment do
    user
    company { association :company, organization: user.organization }
  end
end
