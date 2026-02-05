# frozen_string_literal: true

FactoryBot.define do
  factory :company do
    sequence(:name) { |n| "Test Company #{n}" }
    address_line1 { Faker::Address.street_address }
    city { "Hagåtña" }
    state { "GU" }
    zip { "96910" }
    phone { Faker::PhoneNumber.phone_number }
    email { Faker::Internet.email }
    pay_frequency { "biweekly" }
    active { true }
  end
end
