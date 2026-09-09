# frozen_string_literal: true

FactoryBot.define do
  factory :payroll_filing_responsibility do
    company
    reviewed_by { association :user, company: company, organization: company.organization }
    reviewed_by_name { reviewed_by.name }
    reviewed_by_email { reviewed_by.email }
    reviewed_by_role { reviewed_by.role }
    tax_year { 2026 }
    quarter { 1 }
    filing_type { "form_941" }
    responsible_party { "cornerstone" }
    imported_payroll_inclusion { "included" }
    source_cutoff_date { Date.new(tax_year, 1, 1) }
    reviewed_at { Time.current }
    notes { "Reviewed against the locked migration source." }

    trait :annual do
      quarter { nil }
      filing_type { "w2_gu" }
    end

    trait :external_provider do
      responsible_party { "external_provider" }
      imported_payroll_inclusion { "excluded" }
    end
  end
end
