# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTrackingImport do
  it "keeps finalized payroll batch provenance and payload immutable after preview creation" do
    company = create(:company)
    pay_period = create(:pay_period, company: company)
    source = create(
      :time_tracking_source,
      company: company,
      name: "AIRE",
      source_type: "aire_services",
      base_url: "https://aire.example.com",
      shared_secret: "secret"
    )
    import = described_class.create!(
      pay_period: pay_period,
      time_tracking_source: source,
      start_date: pay_period.start_date,
      end_date: pay_period.end_date,
      fetch_start_date: pay_period.start_date,
      fetch_end_date: pay_period.end_date,
      source_payload_hash: "a" * 64,
      external_batch_id: "AIRE-PAY-IMMUTABLE-001",
      external_batch_checksum: "a" * 64,
      contract_version: "2.0",
      source_cutoff_at: Time.iso8601("2026-08-31T01:00:00Z"),
      raw_payload: { "batch_id" => "AIRE-PAY-IMMUTABLE-001" },
      processed_payload: { "validation_version" => "payroll_batch_v2" },
      warnings: []
    )

    expect(import.update(external_batch_id: "AIRE-PAY-REPLACED-001")).to eq(false)
    expect(import.errors[:base]).to include("Finalized payroll batch provenance and payload cannot be changed after preview creation")
    expect(import.reload.external_batch_id).to eq("AIRE-PAY-IMMUTABLE-001")

    expect(
      import.update(
        external_batch_id: nil,
        external_batch_checksum: nil,
        contract_version: nil,
        source_cutoff_at: nil,
        raw_payload: { "batch_id" => "AIRE-PAY-REPLACED-001" }
      )
    ).to eq(false)
    expect(import.errors[:base]).to include("Finalized payroll batch provenance and payload cannot be changed after preview creation")
    expect(import.reload.external_batch_id).to eq("AIRE-PAY-IMMUTABLE-001")
    expect(import.raw_payload).to eq("batch_id" => "AIRE-PAY-IMMUTABLE-001")

    expect(import.update(status: "applied", applied_at: Time.current)).to eq(true)
  end

  it "keeps historical reconciliation evidence immutable after the payroll is linked" do
    original_reconciled_at = Time.current.round(6)
    original_reconciled_by = create(:user)
    original_exceptions = [ { "employee_id" => 42, "regular_difference_hours" => "-0.03" } ]
    import = create(
      :time_tracking_import,
      reconciled_at: original_reconciled_at,
      reconciled_by: original_reconciled_by,
      reconciliation_note: "Owner approved the legacy reconciliation evidence.",
      reconciliation_exceptions: original_exceptions
    )

    expect(import.update(reconciliation_note: "Replace the original evidence")).to eq(false)
    expect(import.errors[:base]).to include("Historical reconciliation evidence cannot be changed after the payroll is linked")

    expect(import.update(reconciliation_exceptions: [])).to eq(false)
    expect(import.errors[:base]).to include("Historical reconciliation evidence cannot be changed after the payroll is linked")

    expect(import.update(reconciled_at: original_reconciled_at + 1.hour)).to eq(false)
    expect(import.errors[:base]).to include("Historical reconciliation evidence cannot be changed after the payroll is linked")

    expect(import.update(reconciled_by: create(:user))).to eq(false)
    expect(import.errors[:base]).to include("Historical reconciliation evidence cannot be changed after the payroll is linked")

    expect(import.reload).to have_attributes(
      reconciliation_note: "Owner approved the legacy reconciliation evidence.",
      reconciliation_exceptions: original_exceptions,
      reconciled_at: original_reconciled_at,
      reconciled_by: original_reconciled_by
    )
  end

  it "keeps the newest failed acknowledgement visible when failures arrive out of order" do
    company = create(:company)
    pay_period = create(:pay_period, company: company)
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    previous_event_time = Time.iso8601("2026-09-02T08:00:00Z")
    newer_failure_time = Time.iso8601("2026-09-02T10:00:00Z")
    delayed_failure_time = Time.iso8601("2026-09-02T09:00:00Z")
    import = create(
      :time_tracking_import,
      :finalized_aire_batch,
      pay_period: pay_period,
      time_tracking_source: source,
      source_processing_status: "committed",
      source_processing_event_occurred_at: previous_event_time
    )

    expect(
      import.record_source_processing_failure!(
        status: "payment_failed",
        occurred_at: newer_failure_time,
        message: "newer delivery failure"
      )
    ).to eq(true)
    expect(
      import.record_source_processing_failure!(
        status: "payment_issued",
        occurred_at: delayed_failure_time,
        message: "older delayed failure"
      )
    ).to eq(false)

    expect(import.reload).to have_attributes(
      source_processing_event_occurred_at: newer_failure_time,
      source_processing_sync_error: "newer delivery failure"
    )
  end
end
