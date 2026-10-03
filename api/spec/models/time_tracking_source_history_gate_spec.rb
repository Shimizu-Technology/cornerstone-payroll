# frozen_string_literal: true

require "rails_helper"
RSpec.describe TimeTrackingSource do
  it "keeps existing connections blocked until approved installation-bound historical coverage exists" do
    source = create(:time_tracking_source, expected_source_instance_id: SecureRandom.uuid,
      source_protocol: "shimizu_time_payroll", source_protocol_version: "2.0", identity_verified_at: Time.current)
    expect(source.historical_reconciliation_complete?).to be(true)
    source.update_column(:historical_reconciliation_required, true)
    expect(source.historical_reconciliation_complete?).to be(false)
    expect { source.update!(historical_reconciliation_required: false) }.to raise_error(ActiveRecord::RecordInvalid, /cannot be cleared/)
    source.reload
    actor = create(:user, company: source.company, organization: source.company.organization, role: "admin")
    AireVerifiedHistoryRolloutReceipt.create!(company: source.company, time_tracking_source: source,
      manifest_sha256: "a" * 64, identity_count: 0, paid_source_entry_count: 0, completed_at: Time.current)
    expect(source.historical_reconciliation_complete?).to be(false)
    receipt = AireVerifiedHistoryRolloutReceipt.create!(company: source.company, time_tracking_source: source,
      manifest_sha256: "b" * 64, accepted_manifest_sha256: "b" * 64, source_instance_id: source.expected_source_instance_id,
      approved_by: actor, release_owner: "Approved test owner", coverage_verified: true,
      identity_count: 0, paid_source_entry_count: 0, completed_at: Time.current)
    expect(source.historical_reconciliation_complete?).to be(true)
    expect { ApplicationRecord.transaction(requires_new: true) { AireVerifiedHistoryRolloutReceipt.where(id: receipt.id).update_all(coverage_verified: false) } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    source.update!(expected_source_instance_id: SecureRandom.uuid)
    expect(source.historical_reconciliation_complete?).to be(false)
  end

  it "enforces accountant assignments and organization access on approved receipts in Rails and SQL" do
    source = create(:time_tracking_source, expected_source_instance_id: SecureRandom.uuid,
      source_protocol: "shimizu_time_payroll", source_protocol_version: "2.0", identity_verified_at: Time.current)
    company = source.company
    actor = create(:user, role: "accountant", company: create(:company, organization: company.organization))
    attrs = { company: company, time_tracking_source: source, manifest_sha256: "a" * 64,
      accepted_manifest_sha256: "a" * 64, source_instance_id: source.expected_source_instance_id,
      approved_by: actor, release_owner: "Approved test owner", coverage_verified: true,
      identity_count: 0, paid_source_entry_count: 0, completed_at: Time.current }
    expect { AireVerifiedHistoryRolloutReceipt.create!(attrs) }.to raise_error(ActiveRecord::RecordInvalid, /cannot approve/)
    raw = AireVerifiedHistoryRolloutReceipt.new(attrs).attributes.except("id").merge("created_at" => Time.current, "updated_at" => Time.current)
    expect { ApplicationRecord.transaction(requires_new: true) { AireVerifiedHistoryRolloutReceipt.insert_all!([ raw ]) } }
      .to raise_error(ActiveRecord::StatementInvalid, /owner approval/)
    assignment = create(:company_assignment, user: actor, company: company)
    receipt = AireVerifiedHistoryRolloutReceipt.create!(attrs.merge(approved_by: User.find(actor.id)))
    expect(receipt).to be_persisted
    assignment.update!(expires_at: 1.minute.ago)
    expect { ApplicationRecord.transaction(requires_new: true) {
      AireVerifiedHistoryRolloutReceipt.insert_all!([ raw.merge("manifest_sha256" => "b" * 64, "accepted_manifest_sha256" => "b" * 64) ])
    } }.to raise_error(ActiveRecord::StatementInvalid, /owner approval/)
    assignment.update!(expires_at: nil)
    company.organization.update!(status: "inactive")
    expect { ApplicationRecord.transaction(requires_new: true) {
      AireVerifiedHistoryRolloutReceipt.insert_all!([ raw.merge("manifest_sha256" => "c" * 64, "accepted_manifest_sha256" => "c" * 64) ])
    } }.to raise_error(ActiveRecord::StatementInvalid, /owner approval/)
  end
end
