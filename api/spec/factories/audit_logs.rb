# frozen_string_literal: true

FactoryBot.define do
  factory :audit_log do
    action { "records#updated" }
    record_type { "records" }
    event_category { "activity" }
    metadata { {} }

    after(:build) do |log|
      unless log.user || log.actor_type
        log.actor_type = "system_job"
        log.actor_name ||= "System"
      end
    end
  end
end
