# frozen_string_literal: true

FactoryBot.define do
  factory :invoice_billing_profile do
    organization
    sequence(:name) { |n| "Billing Profile #{n}" }
    legal_name { name }
    website { "https://example.com" }
    phone { "671-483-0219" }
    email { "billing@example.com" }
    address { "123 Marine Corps Dr\nHagåtña, GU 96910" }
    payment_instructions { "Please make checks payable to #{name}." }
    default_payment_terms { "Due on receipt" }
    invoice_prefix { "INV" }
    remit_to { name }
    footer_note { "Thank you for your business." }
    active { true }
    is_default { false }
  end
end
