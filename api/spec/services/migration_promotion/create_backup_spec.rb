# frozen_string_literal: true

require "rails_helper"

RSpec.describe MigrationPromotion::CreateBackup do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:target_company) { create(:company, organization: organization, name: "Clean Migration") }
  let(:actor) { create(:user, company: target_company, organization: organization, role: "admin") }
  let(:source_batch) do
    create(
      :historical_import_batch,
      company: target_company,
      status: "locked",
      importer_version: "legacy-test-importer"
    )
  end
  let(:rehearsal) do
    create(
      :company,
      organization: organization,
      name: "Migration Test",
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "migration_rehearsal",
      migration_source_company: target_company,
      migration_source_batch: source_batch,
      migration_rehearsal_status: "ready"
    )
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    first = create(
      :pay_period,
      company: rehearsal,
      status: "calculated",
      start_date: Date.new(2026, 8, 24),
      end_date: Date.new(2026, 9, 6),
      pay_date: Date.new(2026, 9, 10)
    )
    create(
      :pay_period,
      company: rehearsal,
      status: "approved",
      start_date: Date.new(2026, 9, 7),
      end_date: Date.new(2026, 9, 20),
      pay_date: Date.new(2026, 9, 24)
    )
    create(
      :pay_period,
      company: target_company,
      start_date: first.start_date,
      end_date: first.end_date,
      pay_date: first.pay_date
    )
  end

  after { clear_enqueued_jobs }

  it "records the exact clean-client fingerprint and queues a sealed backup copy" do
    fingerprint = MigrationPromotion::TargetFingerprint.call(target_company)

    expect {
      @backup = described_class.new(
        rehearsal: rehearsal,
        actor: actor,
        acknowledgement: described_class::ACKNOWLEDGEMENT
      ).call
    }.to have_enqueued_job(MigrationRehearsal::CloneJob).with(instance_of(Integer), source_batch.id, actor.id)

    expect(@backup).to have_attributes(
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "backup_snapshot",
      migration_source_company: target_company,
      migration_rehearsal_status: "pending"
    )
    expect(@backup.test_workspace_manifest).to include(
      "promotion_source_rehearsal_id" => rehearsal.id,
      "source_fingerprint" => fingerprint,
      "source_draft_pay_period_ids" => target_company.pay_periods.draft.pluck(:id)
    )
    expect(AuditLog.where(action: "migration_promotion#backup_created", company: @backup)).to exist
  end

  it "requires the explicit acknowledgement" do
    expect {
      described_class.new(rehearsal: rehearsal, actor: actor, acknowledgement: "yes").call
    }.to raise_error(ArgumentError, /Confirm creation/)

    expect(target_company.test_workspaces.where(test_workspace_purpose: "backup_snapshot")).to be_empty
  end

  it "archives an outdated snapshot and creates a fresh backup of the current clean client" do
    stale = create(
      :company,
      organization: organization,
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "backup_snapshot",
      migration_source_company: target_company,
      migration_source_batch: source_batch,
      migration_rehearsal_status: "ready",
      test_workspace_sealed_at: 1.hour.ago,
      test_workspace_manifest: {
        "promotion_source_rehearsal_id" => rehearsal.id,
        "source_fingerprint" => "outdated"
      }
    )

    replacement = described_class.new(
      rehearsal: rehearsal,
      actor: actor,
      acknowledgement: described_class::ACKNOWLEDGEMENT
    ).call

    expect(stale.reload).to have_attributes(active: false)
    expect(stale.test_workspace_archived_at).to be_present
    expect(replacement.id).not_to eq(stale.id)
    expect(replacement.test_workspace_manifest.fetch("source_fingerprint")).to eq(
      MigrationPromotion::TargetFingerprint.call(target_company)
    )
  end

  it "archives other active backup snapshots so the new backup is unambiguous" do
    prior = create(
      :company,
      organization: organization,
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "backup_snapshot",
      migration_source_company: target_company,
      migration_source_batch: source_batch,
      migration_rehearsal_status: "ready",
      test_workspace_sealed_at: 1.day.ago,
      test_workspace_manifest: { "promotion_source_rehearsal_id" => rehearsal.id + 100 }
    )

    replacement = described_class.new(
      rehearsal: rehearsal,
      actor: actor,
      acknowledgement: described_class::ACKNOWLEDGEMENT
    ).call

    expect(prior.reload).to have_attributes(active: false)
    expect(prior.test_workspace_archived_at).to be_present
    expect(replacement).to have_attributes(active: true, migration_rehearsal_status: "pending")
  end

  it "replaces a ready snapshot that was never sealed" do
    incomplete = create(
      :company,
      organization: organization,
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "backup_snapshot",
      migration_source_company: target_company,
      migration_source_batch: source_batch,
      migration_rehearsal_status: "ready",
      test_workspace_sealed_at: nil,
      test_workspace_manifest: {
        "promotion_source_rehearsal_id" => rehearsal.id,
        "source_fingerprint" => MigrationPromotion::TargetFingerprint.call(target_company)
      }
    )

    replacement = described_class.new(
      rehearsal: rehearsal,
      actor: actor,
      acknowledgement: described_class::ACKNOWLEDGEMENT
    ).call

    expect(incomplete.reload).to have_attributes(active: false)
    expect(incomplete.test_workspace_archived_at).to be_present
    expect(replacement.id).not_to eq(incomplete.id)
  end
end
