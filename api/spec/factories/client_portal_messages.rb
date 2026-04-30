# frozen_string_literal: true

FactoryBot.define do
  factory :client_portal_message do
    association :client_portal_thread, factory: :client_portal_thread
    company { client_portal_thread.company }
    association :author, factory: :user
    body { "Please use the updated timecard." }
  end
end
