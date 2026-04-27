# frozen_string_literal: true

FactoryBot.define do
  factory :client_document do
    company
    employee { nil }
    association :uploaded_by, factory: :user
    title { "Payroll Source CSV" }
    category { "payroll_source" }
    file_name { "payroll-source.csv" }
    sequence(:file_key) { |n| "client_documents/test/file_#{n}.csv" }
    content_type { "text/csv" }
    file_size { 128 }
    notes { "Uploaded by client" }
  end
end
