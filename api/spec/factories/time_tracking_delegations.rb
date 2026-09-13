# frozen_string_literal: true

FactoryBot.define do
  factory :time_tracking_delegation do
    company
    time_tracking_source { association(:time_tracking_source, company: company, source_type: "aire_services") }
    user { association(:user, company: company, organization: company.organization, role: "admin") }
    token { "aire-delegation-token" }
  end
end
