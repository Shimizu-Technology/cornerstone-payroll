# frozen_string_literal: true

FactoryBot.define do
  factory :invoice_recipient do
    company
    organization { company.organization }
    sequence(:name) { |n| "Invoice Recipient #{n}" }
    email { "billing@example.com" }
    address { "123 Marine Corps Dr\nHagåtña, GU 96910" }
    default_rate { 125.00 }
    invoice_prefix { "INV" }
    payment_terms { "Due on receipt" }
    template_type { "standard" }
    active { true }
  end
end
