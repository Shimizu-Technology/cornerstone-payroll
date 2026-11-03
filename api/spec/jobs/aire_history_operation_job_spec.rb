# frozen_string_literal: true

require "rails_helper"
require "support/aire_history_approval_evidence"

RSpec.describe AireHistoryOperationJob do
  include_context "aire history approval evidence"

  def operation(kind, arguments)
    AireHistoryOperation.create!(company: company, time_tracking_source: source, actor: actor,
      kind: kind, request_key: SecureRandom.uuid, arguments: arguments)
  end

  it "captures and approves in durable jobs, retaining the terminal result atomically and making retries harmless" do
    preview = operation("preview", mapping_selections: [])
    described_class.perform_now(preview.id)
    page = preview.reload.result
    expect(preview.status).to eq("completed")
    expect(page["history_coverage_verified"]).to be(true)
    approval = operation("approve", page.slice("review_id", "digest", "attestation").merge(confirmed_mapping_uuids: [], solo_choices: []))
    described_class.perform_now(approval.id)
    expect(approval.reload.result["approved_at"]).to be_present
    expect(approval.status).to eq("completed")
    expect(client).not_to receive(:payroll_cockpit_history_entries)
    described_class.perform_now(approval.id)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(1)
    expect(CheckEvent.count).to eq(0)
  end

  it "retains exact stale-source failures and applies nothing" do
    page = history_service.prepare!
    approval = operation("approve", page.slice("review_id", "digest", "attestation"))
    row["version"] += 1
    described_class.perform_now(approval.id)
    expect(approval.reload).to have_attributes(status: "failed", result: nil)
    expect(approval.source_changes).to include(a_string_matching(/41/))
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end

  it "rechecks pause and permissions before reading or applying history" do
    preview = operation("preview", mapping_selections: [])
    allow(ConnectedPayrollMode).to receive(:enabled?).and_return(false)
    expect(client).not_to receive(:payroll_cockpit_history_entries)
    described_class.perform_now(preview.id)
    expect(preview.reload).to have_attributes(status: "failed", error: a_string_matching(/paused/))
    allow(ConnectedPayrollMode).to receive(:enabled?).and_return(true)
    actor.update!(role: "manager")
    revoked = operation("preview", mapping_selections: [])
    described_class.perform_now(revoked.id)
    expect(revoked.reload.status).to eq("failed")
    expect(AireHistoryReview.count).to eq(0)
  end

  it "rolls back the approval if saving its terminal operation result fails" do
    page = history_service.prepare!
    approval = operation("approve", page.slice("review_id", "digest", "attestation"))
    allow_any_instance_of(AireHistoryOperation).to receive(:update!).and_wrap_original do |method, **attributes|
      raise "simulated terminal-result failure" if attributes[:status] == "completed"
      method.call(**attributes)
    end
    expect { described_class.perform_now(approval.id) }.to raise_error(/simulated terminal-result failure/)
    expect(approval.reload.status).to eq("failed")
    expect(AireHistoryReview.find(page["review_id"]).approved_at).to be_nil
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
    expect(AuditLog.where(action: "aire_history#approved")).not_to exist
  end
end
