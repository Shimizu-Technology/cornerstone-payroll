# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::CutoverVerificationJob, type: :job do
  before { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }

  let!(:company) { create(:company, historical_payroll_enabled: true) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:batch) do
    imported = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch
    review_historical_workers_as_archive_only(imported, actor: actor)
    QuickbooksHistory::LifecycleService.new(batch: imported, actor: actor).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
    imported
  end

  after do
    cleanup_quickbooks_history_uploads
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
  end

  it "finishes a queued verification and persists its evidence" do
    queued = QuickbooksHistory::CutoverVerificationEnqueueService.new(batch: batch, actor: actor).call

    described_class.perform_now(batch.id, actor.id, queued.review.verification_started_at.iso8601(6))

    expect(queued.review.reload.status).to eq("verified")
    expect(queued.review.evidence.fetch("checks")).to all(include("passed" => true))
  end

  it "persists a safe failed state when background verification raises" do
    review = QuickbooksHistory::CutoverVerificationEnqueueService.new(batch: batch, actor: actor).call.review
    allow(QuickbooksHistory::CutoverVerificationService).to receive(:new).and_raise(StandardError, "private adapter detail")

    described_class.perform_now(batch.id, actor.id, review.verification_started_at.iso8601(6))

    expect(review.reload.status).to eq("failed")
    expect(review.verification_error).to eq("Cutover verification could not be completed. Review the source files and try again.")
    expect(review.verification_error).not_to include("private adapter detail")
    expect(AuditLog.where(action: "historical_imports#cutover_verification_failed", record_id: review.id)).to exist
  end

  it "does not let a superseded job overwrite a newer verification attempt" do
    review = QuickbooksHistory::CutoverVerificationEnqueueService.new(batch: batch, actor: actor).call.review
    superseded_token = review.verification_started_at.iso8601(6)
    review.update_columns(verification_started_at: 1.second.from_now)

    expect do
      described_class.perform_now(batch.id, actor.id, superseded_token)
    end.not_to change { review.reload.status }

    expect(review).to be_pending
    expect(AuditLog.where(action: "historical_imports#verify_cutover", record_id: review.id)).not_to exist
  end

  it "fails safely if the initiating operator loses access before execution" do
    review = QuickbooksHistory::CutoverVerificationEnqueueService.new(batch: batch, actor: actor).call.review
    actor.update!(active: false)

    described_class.perform_now(batch.id, actor.id, review.verification_started_at.iso8601(6))

    expect(review.reload.status).to eq("failed")
    expect(review.verification_error).to eq("Cutover verification could not be completed. Review the source files and try again.")
    expect(AuditLog.where(action: "historical_imports#verify_cutover", record_id: review.id)).not_to exist
  end
end
