# frozen_string_literal: true

FactoryBot.define do
  factory :aire_payroll_calendar_period do
    company
    time_tracking_source { association(:time_tracking_source, source_type: "aire_services", company: company) }
    pay_period { association(:pay_period, company: company) }
    external_pay_period_id { SecureRandom.uuid }
  end

  factory :aire_payroll_calendar_publication do
    aire_payroll_calendar_period
    schedule_version { 1 }
    publication_id { SecureRandom.uuid }
    payload do
      {
        "schema_version" => "1.0",
        "start_date" => "2026-10-01",
        "end_date" => "2026-10-15",
        "pay_date" => "2026-10-25",
        "cutoff_at" => "2026-10-18T17:00:00+10:00",
        "time_zone" => "Pacific/Guam",
        "cutoff_days_before" => 7,
        "schedule_version" => schedule_version,
        "publication_id" => publication_id
      }
    end
    payload_checksum { TimeTracking::CanonicalPayload.checksum(payload) }
    next_delivery_attempt_at { Time.current }
  end
end
