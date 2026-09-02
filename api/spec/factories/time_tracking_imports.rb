# frozen_string_literal: true

FactoryBot.define do
  factory :time_tracking_import do
    pay_period
    time_tracking_source
    status { "previewed" }
    start_date { pay_period.start_date }
    end_date { pay_period.end_date }
    fetch_start_date { pay_period.start_date }
    fetch_end_date { pay_period.end_date }
    source_payload_hash { Digest::SHA256.hexdigest("time-tracking-import-#{pay_period.id}") }
    raw_payload { {} }
    processed_payload { {} }
    warnings { [] }

    trait :finalized_aire_batch do
      sequence(:external_batch_id) { |n| "AIRE-PAY-FACTORY-#{n}" }
      external_batch_checksum { "a" * 64 }
      contract_version { "2.0" }
      source_cutoff_at { Time.current }
      source_payload_hash { external_batch_checksum }
    end
  end
end
