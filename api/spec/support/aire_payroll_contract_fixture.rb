# frozen_string_literal: true

module AirePayrollContractFixture
  def build_aire_batch_payload(
    batch_id: "AIRE-PAY-20261015-ABC123",
    start_date: "2026-10-01",
    end_date: "2026-10-15",
    cutoff_at: "2026-10-18T07:00:00Z"
  )
    payload = {
      "schema_version" => "2.0",
      "source" => "aire_services",
      "batch_id" => batch_id,
      "start_date" => start_date,
      "end_date" => end_date,
      "cutoff_at" => cutoff_at,
      "generated_at" => cutoff_at,
      "employees" => [
        {
          "source_user_id" => "42",
          "email" => "pilot@example.com",
          "display_name" => "Pilot One",
          "adjustments" => [
            {
              "source_time_entry_id" => "101",
              "line_key" => "7:2500",
              "source_kind" => "current",
              "original_work_date" => "2026-10-05",
              "original_week_start" => "2026-10-04",
              "source_category_id" => "7",
              "category" => { "id" => 7, "key" => "flight_hours", "name" => "Flight Hours" },
              "total_hours" => 8.0,
              "regular_hours" => 8.0,
              "overtime_hours" => 0.0
            }
          ],
          "total_hours" => 8.0,
          "regular_hours" => 8.0,
          "overtime_hours" => 0.0
        }
      ],
      "exclusions" => [
        {
          "source_time_entry_id" => "202",
          "source_user_id" => "42",
          "reason" => "pending_approval",
          "original_work_date" => "2026-10-06",
          "held_total_hours" => 4.0,
          "held_regular_hours" => 4.0,
          "held_overtime_hours" => 0.0
        }
      ],
      "issues" => {
        "missing_category_count" => 0,
        "negative_adjustment_count" => 0,
        "pending_approval_count" => 1,
        "denied_approval_count" => 0,
        "open_clock_count" => 0,
        "pending_overtime_count" => 0,
        "denied_overtime_count" => 0
      },
      "summary" => {
        "employee_count" => 1,
        "adjustment_count" => 1,
        "exclusion_count" => 1,
        "total_hours" => 8.0,
        "regular_hours" => 8.0,
        "overtime_hours" => 0.0,
        "current_count" => 1,
        "carryover_count" => 0,
        "correction_count" => 0
      }
    }
    payload["export"] = {
      "id" => batch_id,
      "batch_id" => batch_id,
      "readiness_status" => "finalized",
      "cutoff_at" => cutoff_at,
      "finalized_at" => Time.iso8601(cutoff_at).advance(seconds: 1).iso8601,
      "checksum_algorithm" => "SHA-256",
      "checksum_scope" => "payload_without_export",
      "checksum" => TimeTracking::CanonicalPayload.checksum(payload)
    }
    payload
  end

  def build_aire_finalized_event(calendar_period:, publication:, batch_payload:, event_id: SecureRandom.uuid)
    {
      "schema_version" => "1.0",
      "event_id" => event_id,
      "event_type" => "payroll_batch.finalized",
      "occurred_at" => batch_payload.dig("export", "finalized_at"),
      "source" => "aire_services",
      "payroll_period" => publication.payload.except("schema_version").merge(
        "external_pay_period_id" => calendar_period.external_pay_period_id,
        "status" => "finalized",
        "cutoff_state" => "finalized",
        "payroll_batch_id" => batch_payload["batch_id"],
        "finalized_at" => batch_payload.dig("export", "finalized_at")
      ),
      "payroll_batch" => {
        "id" => batch_payload["batch_id"],
        "checksum" => batch_payload.dig("export", "checksum"),
        "schema_version" => batch_payload["schema_version"],
        "start_date" => batch_payload["start_date"],
        "end_date" => batch_payload["end_date"],
        "cutoff_at" => batch_payload["cutoff_at"],
        "finalized_at" => batch_payload.dig("export", "finalized_at"),
        "summary" => batch_payload["summary"],
        "issues" => batch_payload["issues"]
      }
    }
  end
end

RSpec.configure do |config|
  config.include AirePayrollContractFixture
end
