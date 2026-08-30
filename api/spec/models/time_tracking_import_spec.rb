# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTrackingImport do
  it "keeps finalized payroll batch provenance and payload immutable after preview creation" do
    company = create(:company)
    pay_period = create(:pay_period, company: company)
    source = TimeTrackingSource.create!(
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

    expect(import.update(status: "applied", applied_at: Time.current)).to eq(true)
  end
end
