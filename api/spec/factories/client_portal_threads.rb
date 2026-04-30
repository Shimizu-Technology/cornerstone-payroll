# frozen_string_literal: true

FactoryBot.define do
  factory :client_portal_thread do
    company
    association :created_by, factory: :user
    subject { "Payroll source files" }
    status { "open" }
    last_message_at { nil }
  end
end
