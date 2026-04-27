# frozen_string_literal: true

FactoryBot.define do
  factory :employee_change_request do
    company
    employee
    association :requested_by, factory: :user
    reviewed_by { nil }
    status { :pending }
    proposed_changes { { pay_rate: 22.5 } }
    original_values { { pay_rate: 18.0 } }
    direct_changes_applied { {} }
    request_notes { "Pending approval for payroll-sensitive fields" }
    review_notes { nil }
    reviewed_at { nil }
  end
end
