# frozen_string_literal: true

FactoryBot.define do
  factory :company do
    organization
    sequence(:name) { |n| "Test Company #{n}" }
    address_line1 { "123 Marine Corps Dr" }
    city { "Hagåtña" }
    state { "GU" }
    zip { "96910" }
    filing_contact_name { "Example Contact" }
    phone { "6715551234" }
    sequence(:email) { |n| "contact#{n}@example.com" }
    pay_frequency { "biweekly" }
    active { true }
  end
end
