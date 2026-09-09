# frozen_string_literal: true

require "rails_helper"

RSpec.describe Company, type: :model do
  it "allows an exact source EIN only on a linked rehearsal in the same organization" do
    organization = create(:organization)
    source = create(:company, organization: organization, ein: "12-3456789")
    batch = create(:historical_import_batch, company: source, status: "locked")
    rehearsal = build(
      :company,
      organization: organization,
      ein: source.ein,
      payroll_environment: "migration_rehearsal",
      migration_source_company: source,
      migration_source_batch: batch,
      migration_rehearsal_status: "pending"
    )

    expect(rehearsal).to be_valid
    expect(build(:company, organization: organization, ein: source.ein)).not_to be_valid
  end

  it "rejects a rehearsal linked across organizations" do
    source = create(:company)
    batch = create(:historical_import_batch, company: source, status: "locked")
    rehearsal = build(
      :company,
      organization: create(:organization),
      payroll_environment: "migration_rehearsal",
      migration_source_company: source,
      migration_source_batch: batch,
      migration_rehearsal_status: "pending"
    )

    expect(rehearsal).not_to be_valid
    expect(rehearsal.errors.full_messages.join).to include("same organization")
  end

  it "allows draft practice periods before YTD activation but keeps calculation gated" do
    organization = create(:organization)
    source = create(:company, organization: organization, historical_payroll_enabled: true)
    batch = create(
      :historical_import_batch,
      company: source,
      status: "locked",
      importer_version: HistoricalImportBatch::YTD_BRIDGE_IMPORTER_VERSIONS.first
    )
    rehearsal = create(
      :company,
      organization: organization,
      payroll_environment: "migration_rehearsal",
      migration_source_company: source,
      migration_source_batch: batch,
      migration_rehearsal_status: "ready"
    )
    create(
      :historical_import_batch,
      company: rehearsal,
      status: "locked",
      importer_version: HistoricalImportBatch::YTD_BRIDGE_IMPORTER_VERSIONS.first
    )
    period = PayPeriod.new(
      company: rehearsal,
      start_date: Date.new(2026, 8, 15),
      end_date: Date.new(2026, 8, 28),
      pay_date: Date.new(2026, 9, 4),
      status: "draft"
    )

    expect(period.save).to be(true)
    expect(period).to be_parallel_run
    expect(period.valid?(:payroll_calculation)).to be(false)
    expect(period.errors.full_messages.join).to include("Activate the verified historical YTD opening balances")
  end
end
