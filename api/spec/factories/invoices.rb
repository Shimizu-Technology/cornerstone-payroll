# frozen_string_literal: true

FactoryBot.define do
  factory :invoice do
    company
    organization { company.organization }
    invoice_billing_profile { association(:invoice_billing_profile, organization: organization) }
    invoice_recipient { association(:invoice_recipient, company: company) }
    sequence(:invoice_number) { |n| "INV-2026-#{n.to_s.rjust(4, '0')}" }
    invoice_date { Date.new(2026, 5, 2) }
    service_period_start { Date.new(2026, 5, 1) }
    service_period_end { Date.new(2026, 5, 15) }
    status { "draft" }
    payment_terms { "Due on receipt" }
    notes { "Thank you for your business." }
    trait :with_line_item do
      after(:build) do |invoice|
        invoice.line_items.build(
          description: "Payroll services",
          quantity: 2,
          rate: 150,
          position: 0
        )
      end
    end

    trait :generated do
      status { "open" }
      issued_at { Time.current }
      generated_at { Time.current }
    end
  end
end
