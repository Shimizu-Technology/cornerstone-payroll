# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::PayrollBatchPayloadValidator do
  def valid_payload
    payload = {
      "schema_version" => "2.0",
      "source" => "aire_services",
      "batch_id" => "AIRE-PAY-20260830-ABC123",
      "start_date" => "2026-08-16",
      "end_date" => "2026-08-31",
      "cutoff_at" => "2026-08-31T01:00:00Z",
      "generated_at" => "2026-08-31T01:00:00Z",
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
              "original_work_date" => "2026-08-17",
              "original_week_start" => "2026-08-16",
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
          "original_work_date" => "2026-08-18",
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
      "id" => payload["batch_id"],
      "batch_id" => payload["batch_id"],
      "readiness_status" => "finalized",
      "cutoff_at" => payload["cutoff_at"],
      "finalized_at" => "2026-08-31T01:00:01Z",
      "checksum_algorithm" => "SHA-256",
      "checksum_scope" => "payload_without_export",
      "checksum" => TimeTracking::CanonicalPayload.checksum(payload)
    }
    payload
  end

  it "accepts a reconciled finalized AIRE batch with a canonical checksum" do
    payload = valid_payload

    expect(described_class.new(payload: payload, start_date: "2026-08-16", end_date: "2026-08-31").validate!).to equal(payload)
  end

  it "rejects a payload changed after finalization" do
    payload = valid_payload
    payload["employees"][0]["total_hours"] = 9.0

    expect do
      described_class.new(payload: payload, start_date: "2026-08-16", end_date: "2026-08-31").validate!
    end.to raise_error(described_class::Error, /checksum verification failed/)
  end

  it "rejects a mathematically inconsistent employee even with a valid checksum" do
    payload = valid_payload
    payload["employees"][0]["total_hours"] = 9.0
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))

    expect do
      described_class.new(payload: payload, start_date: "2026-08-16", end_date: "2026-08-31").validate!
    end.to raise_error(described_class::Error, /employees\[0\]\.total_hours does not reconcile/)
  end

  it "only allows negative hours on correction lines" do
    payload = valid_payload
    adjustment = payload["employees"][0]["adjustments"][0]
    adjustment.merge!("total_hours" => -8.0, "regular_hours" => -8.0)
    payload["employees"][0].merge!("total_hours" => -8.0, "regular_hours" => -8.0)
    payload["summary"].merge!("total_hours" => -8.0, "regular_hours" => -8.0)
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))

    expect do
      described_class.new(payload: payload, start_date: "2026-08-16", end_date: "2026-08-31").validate!
    end.to raise_error(described_class::Error, /negative hours but is not a correction/)
  end

  it "rejects an adjustment attributed to a different permanent AIRE user" do
    payload = valid_payload
    payload["employees"][0]["source_user_uuid"] = SecureRandom.uuid
    payload["employees"][0]["adjustments"][0]["source_user_uuid"] = SecureRandom.uuid
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))

    expect do
      described_class.new(payload: payload, start_date: "2026-08-16", end_date: "2026-08-31").validate!
    end.to raise_error(described_class::Error, /does not match its employee/)
  end

  it "keeps payable categories mandatory for ordinary finalized-batch imports" do
    payload = valid_payload
    payload["employees"][0]["adjustments"][0].merge!("source_category_id" => nil, "category" => nil)
    payload["issues"]["missing_category_count"] = 1
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))

    expect do
      described_class.new(payload: payload, start_date: "2026-08-16", end_date: "2026-08-31").validate!
    end.to raise_error(described_class::Error, /category must be an object/)
  end

  it "accepts checksum-bound uncategorized legacy entries only for historical reconciliation" do
    payload = valid_payload
    payload["employees"][0]["adjustments"][0].merge!("source_category_id" => nil, "category" => nil)
    payload["issues"]["missing_category_count"] = 1
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))

    result = described_class.new(
      payload: payload,
      start_date: "2026-08-16",
      end_date: "2026-08-31",
      allow_legacy_uncategorized: true
    ).validate!

    expect(result).to equal(payload)
  end

  it "verifies the declared legacy missing-category count" do
    payload = valid_payload
    payload["employees"][0]["adjustments"][0].merge!("source_category_id" => nil, "category" => nil)
    payload["issues"]["missing_category_count"] = 2
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))

    expect do
      described_class.new(
        payload: payload,
        start_date: "2026-08-16",
        end_date: "2026-08-31",
        allow_legacy_uncategorized: true
      ).validate!
    end.to raise_error(described_class::Error, /missing_category_count does not reconcile/)
  end

  it "rejects a fractional missing-category count near the actual integer count" do
    payload = valid_payload
    payload["employees"][0]["adjustments"][0].merge!("source_category_id" => nil, "category" => nil)
    payload["issues"]["missing_category_count"] = 0.995
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))

    expect do
      described_class.new(
        payload: payload,
        start_date: "2026-08-16",
        end_date: "2026-08-31",
        allow_legacy_uncategorized: true
      ).validate!
    end.to raise_error(described_class::Error, /missing_category_count does not reconcile/)
  end
end
