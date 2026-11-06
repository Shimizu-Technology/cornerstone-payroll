# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendar::HistoricalImportBoundaryReview do
  let(:source) { create(:time_tracking_source, source_type: "aire_services") }
  let(:run) do
    create(:pay_period, :committed, company: source.company, start_date: "2026-09-01", end_date: "2026-09-15",
      pay_date: "2026-09-30", committed_at: Time.utc(2026, 9, 30, 7))
  end
  let!(:record) do
    create(:time_tracking_import, time_tracking_source: source, pay_period: run, raw_payload: { "source" => "aire_services" },
      created_at: Time.utc(2026, 9, 30, 8))
  end
  subject(:review) { described_class.new(source: source) }

  def configure(digest)
    AirePayrollCalendar::LockRollout.new(source: source, starts_on: "2026-11-01", actor: "Rehearsal reviewer",
      reason: "Reviewed retained preactivation imports without changing wages", historical_imports_sha256: digest).configure!
  end

  it "requires an exact explicit digest before recording the immutable attributed selection" do
    preview = review.preview!
    expect(preview.fetch("inventory").sole).to include("import_id" => record.id, "run_id" => run.id)
    expect { configure(nil) }.to raise_error(AirePayrollCalendar::LockRollout::Error, /exact HISTORICAL_IMPORTS_SHA256/)
    expect(TimeTrackingLockRolloutSelection.count).to eq(0)
    expect { configure(preview.fetch("sha256")) }.to change(TimeTrackingLockRolloutSelection, :count).by(1)
    expect(source.reload.lock_rollout_selection.historical_import_review).to eq(preview)
    expect(source[:cutoff_enforcement_starts_on]).to eq(Date.new(2026, 10, 16))
    expect(AuditLog.find_by!(action: "time_tracking_source#initial_lock_rollout_selected").metadata)
      .to include("historical_import_review" => preview)
  end

  it "refuses stale import and run fingerprints at both the service and database boundaries" do
    preview = review.preview!
    record.update!(warnings: [ "Reviewed inventory changed" ])
    expect { review.verify!(accepted_sha256: preview.fetch("sha256")) }.to raise_error(described_class::Error, /exact/)
    expect do
      TimeTrackingLockRolloutSelection.transaction(requires_new: true) do
        source.create_lock_rollout_selection!(starts_on: "2026-11-01", actor: "Reviewer",
          reason: "Review of stale historical evidence", historical_import_review: preview)
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /exact reviewed/)
    fresh = review.preview!
    run.update_columns(notes: "Register context changed")
    expect { review.verify!(accepted_sha256: fresh.fetch("sha256")) }.to raise_error(described_class::Error, /exact/)
  end

  [ { "allocation_contract_version" => "guam_intervals_v1" }, { "overtime_policy" => { "calculation" => "weekly_only" } },
    { "calendar" => { "id" => "connected" } }, { "payroll_calendar_period_id" => "connected" },
    { "target_external_pay_period_id" => "123" } ].each do |connected_marker|
    it "refuses connected marker #{connected_marker.keys.sole} despite older nominal dates" do
      record.update!(raw_payload: record.raw_payload.merge(connected_marker))
      expect { review.preview! }.to raise_error(described_class::Error, /Connected/)
      expect do
        TimeTrackingLockRolloutSelection.transaction(requires_new: true) do
          source.create_lock_rollout_selection!(starts_on: "2026-11-01", actor: "Reviewer", reason: "Reviewed connected marker refusal")
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /exact reviewed/)
    end
  end

  it "rejects later imports, uncommitted runs and partial frozen metadata" do
    record.update_columns(created_at: Time.utc(2026, 10, 16, 1))
    expect { review.preview! }.to raise_error(described_class::Error)
    record.update_columns(created_at: Time.utc(2026, 9, 30, 8))
    expect do
      TimeTrackingImport.transaction(requires_new: true) { record.update_columns(contract_version: "2.0") }
    end.to raise_error(ActiveRecord::StatementInvalid, /batch_provenance_complete/)
    run.update_columns(status: "approved")
    expect { review.preview! }.to raise_error(described_class::Error)
  end

  context "with an original frozen preactivation import" do
    let(:payload) do
      body = { "source" => "aire_services", "schema_version" => "2.0", "batch_id" => "AIRE-SYNTHETIC-LEGACY",
        "start_date" => "2026-09-01", "end_date" => "2026-09-15", "cutoff_at" => "2026-09-30T06:00:00Z",
        "generated_at" => "2026-09-30T06:00:00Z", "employees" => [], "exclusions" => [],
        "summary" => %w[employee_count adjustment_count exclusion_count total_hours regular_hours overtime_hours current_count carryover_count correction_count].index_with { 0 },
        "issues" => %w[missing_category_count negative_adjustment_count pending_approval_count denied_approval_count open_clock_count pending_overtime_count denied_overtime_count].index_with { 0 } }
      body.merge("export" => { "id" => body["batch_id"], "batch_id" => body["batch_id"], "checksum_algorithm" => "SHA-256",
        "checksum_scope" => "payload_without_export", "readiness_status" => "finalized", "cutoff_at" => body["cutoff_at"],
        "finalized_at" => body["cutoff_at"], "checksum" => TimeTracking::CanonicalPayload.checksum(body) })
    end

    before do
      record.update!(status: "applied", external_batch_id: payload["batch_id"], contract_version: "2.0",
        external_batch_checksum: payload.dig("export", "checksum"), source_cutoff_at: Time.utc(2026, 9, 30, 6),
        source_processing_status: "committed", source_processing_event_occurred_at: run.committed_at, raw_payload: payload)
    end

    it "accepts a reviewed checksum-verified historical snapshot without financial side effects" do
      before = [ PayrollItem.count, TimeTrackingEntryAllocation.count, CheckEvent.count ]
      expect(configure(review.preview!.fetch("sha256"))).to include(status: "configured")
      expect([ PayrollItem.count, TimeTrackingEntryAllocation.count, CheckEvent.count ]).to eq(before)
      expect(record.reload.raw_payload).to eq(payload)
    end

    it "rejects checksum tampering even when all local processing fields still match" do
      tampered = payload.deep_dup
      tampered["summary"]["regular_hours"] = 1
      # Model immutability is preserved; bypass it only to test the independent verifier.
      record.update_columns(raw_payload: tampered)
      expect { review.preview! }.to raise_error(described_class::Error, /checksum/)
    end

    it "rejects an unconfirmed processing link" do
      record.update_columns(source_processing_status: "imported")
      expect { review.preview! }.to raise_error(described_class::Error, /unsupported/)
    end
  end
end
