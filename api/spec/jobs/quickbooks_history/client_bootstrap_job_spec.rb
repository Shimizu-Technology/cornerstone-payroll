# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::ClientBootstrapJob, type: :job do
  before { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }

  let!(:company) { create(:company, historical_payroll_enabled: true) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:batch) do
    QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch
  end
  let!(:bootstrap) do
    QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
  end

  after do
    cleanup_quickbooks_history_uploads
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
  end

  def enqueue_bootstrap
    QuickbooksHistory::ClientBootstrapEnqueueService.new(
      bootstrap: bootstrap,
      actor: actor,
      acknowledgement: QuickbooksHistory::ClientBootstrapApplyService::ACKNOWLEDGEMENT
    ).call.bootstrap
  end

  it "prepares the clean client outside the request thread" do
    pending_bootstrap = enqueue_bootstrap

    described_class.perform_now(pending_bootstrap.id, actor.id, pending_bootstrap.apply_started_at.iso8601(6))

    expect(pending_bootstrap.reload).to be_applied
    expect(company.employees.count).to eq(3)
    expect(batch.historical_paychecks.where(employee_id: nil)).to be_empty
  end

  it "persists a safe failed state when background preparation raises" do
    pending_bootstrap = enqueue_bootstrap
    allow(QuickbooksHistory::ClientBootstrapApplyService).to receive(:new).and_raise(StandardError, "private adapter detail")
    allow(Rails.logger).to receive(:error)

    described_class.perform_now(pending_bootstrap.id, actor.id, pending_bootstrap.apply_started_at.iso8601(6))

    expect(pending_bootstrap.reload).to be_failed
    expect(pending_bootstrap.apply_error).to eq("Employee preparation could not be completed. Review the current setup preview and try again.")
    expect(pending_bootstrap.apply_error).not_to include("private adapter detail")
    expect(AuditLog.where(action: "historical_imports#client_bootstrap_failed", record_id: pending_bootstrap.id)).to exist
  end

  it "keeps the attempt pending and retries transient database contention" do
    pending_bootstrap = enqueue_bootstrap
    allow(QuickbooksHistory::ClientBootstrapApplyService).to receive(:new).and_raise(ActiveRecord::Deadlocked, "retryable")

    expect do
      described_class.perform_now(pending_bootstrap.id, actor.id, pending_bootstrap.apply_started_at.iso8601(6))
    end.to have_enqueued_job(described_class).with(pending_bootstrap.id, actor.id, pending_bootstrap.apply_started_at.iso8601(6))

    expect(pending_bootstrap.reload).to be_pending
    expect(pending_bootstrap.apply_error).to be_nil
  end

  it "does not let a superseded job mutate a newer attempt" do
    pending_bootstrap = enqueue_bootstrap
    superseded_token = pending_bootstrap.apply_started_at.iso8601(6)
    pending_bootstrap.update_columns(apply_started_at: 1.second.from_now)

    expect do
      described_class.perform_now(pending_bootstrap.id, actor.id, superseded_token)
    end.not_to change(Employee, :count)

    expect(pending_bootstrap.reload).to be_pending
  end
end
