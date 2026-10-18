# frozen_string_literal: true

require "rails_helper"

RSpec.describe "QuickBooks client management delayed revocation" do
  let!(:company) { create(:company) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: :admin) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: :accountant) }
  let!(:assignment) { create(:company_assignment, user: actor, company: company, granted_by: admin, client_management: true) }
  let!(:batch) do
    QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
  end
  let(:worker) { batch.historical_workers.find_by!(source_name: "Worker, Alice") }
  let(:employee) { create(:employee, company: company) }

  def revoke_during_lock(record)
    allow(record).to receive(:lock!).and_wrap_original do |original, *args|
      assignment.update!(client_management: false)
      original.call(*args)
    end
  end

  def apply_batch
    review_historical_workers_as_archive_only(batch, actor: admin)
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
  end

  it "does not remap either workers or paychecks after revocation during worker lock acquisition" do
    target = worker
    revoke_during_lock(target)
    expect(AuditLog).not_to receive(:record!)

    expect do
      QuickbooksHistory::MappingService.new(worker: target, employee: employee, actor: actor).call
    end.to raise_error(ArgumentError, /company access/)

    expect(target.reload).to have_attributes(employee_id: nil, mapping_status: "needs_review")
    expect(target.historical_paychecks.distinct.pluck(:employee_id)).to eq([ nil ])
  end

  it "does not bulk archive workers or audit after revocation while acquiring the batch lock" do
    revoke_during_lock(batch)
    expect(AuditLog).not_to receive(:record!)

    result = QuickbooksHistory::BulkArchiveOnlyService.new(batch: batch, actor: actor).call

    expect(result).not_to be_success
    expect(result.error.message).to include("company access")
    expect(batch.historical_workers.distinct.pluck(:mapping_status)).to eq([ "needs_review" ])
  end

  %i[apply! lock!].each do |operation|
    it "does not #{operation} history when the grant is revoked during retained-source verification" do
      if operation == :lock!
        apply_batch
        approve_historical_cutover(batch, actor: admin)
      else
        review_historical_workers_as_archive_only(batch, actor: admin)
      end
      initial_status = batch.reload.status
      allow_any_instance_of(QuickbooksHistory::SourceFileVerificationService).to receive(:call).and_wrap_original do |original|
        result = original.call
        expect(result.all_verified).to be(true)
        assignment.update!(client_management: false)
        expect(AuditLog).not_to receive(:record!)
        result
      end
      service = QuickbooksHistory::LifecycleService.new(batch: batch, actor: actor)

      expect do
        if operation == :apply!
          service.apply!(acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT)
        else
          service.lock!
        end
      end.to raise_error(ArgumentError, /company access/)

      expect(batch.reload.status).to eq(initial_status)
      expect(batch.locked_at).to be_nil
      expect(batch.applied_at).to be_nil if operation == :apply!
    end
  end

  %i[save! approve!].each do |operation|
    it "does not #{operation} cutover evidence or audit after revocation during review lock acquisition" do
      apply_batch
      review = HistoricalImportCutoverReview.create!(company: company, historical_import_batch: batch,
        status: "verified", evidence: { "passed" => true, "exceptions" => [] }, evidence_digest: "a" * 64,
        verified_at: Time.current, verified_by: admin,
        attestations: HistoricalImportCutoverReview::ATTESTATIONS.keys.index_with(true))
      revoke_during_lock(review)
      expect(AuditLog).not_to receive(:record!)
      service = QuickbooksHistory::CutoverReviewService.new(review: review, actor: actor)

      expect do
        if operation == :save!
          service.save!(exception_dispositions: {}, attestations: {}, approval_notes: "Changed")
        else
          service.approve!(acknowledgement: HistoricalImportCutoverReview::APPROVAL_ACKNOWLEDGEMENT)
        end
      end.to raise_error(ArgumentError, /company access/)

      expect(review.reload).to have_attributes(status: "verified", approval_notes: nil, approved_at: nil)
      expect(review.attestations.values).to all(be(true))
    end
  end

  it "does not reset review evidence, audit or enqueue after revocation during the batch lock" do
    apply_batch
    review = HistoricalImportCutoverReview.create!(company: company, historical_import_batch: batch,
      status: "verified", evidence: { "passed" => true }, evidence_digest: "a" * 64,
      verified_at: Time.current, verified_by: admin, approval_notes: "Retain this review")
    revoke_during_lock(batch)
    expect(AuditLog).not_to receive(:record!)
    expect(QuickbooksHistory::CutoverVerificationJob).not_to receive(:perform_later)

    expect do
      QuickbooksHistory::CutoverVerificationEnqueueService.new(batch: batch, actor: actor).call
    end.to raise_error(ArgumentError, /company access/)

    expect(review.reload).to have_attributes(status: "verified", evidence_digest: "a" * 64,
      approval_notes: "Retain this review", verification_started_at: nil)
  end
  it "does not dispatch a verification job if the grant is revoked after the pending transaction commits" do
    apply_batch
    service = QuickbooksHistory::CutoverVerificationEnqueueService.new(batch: batch, actor: actor)
    allow(service).to receive(:prepare_pending_review!).and_wrap_original do |original|
      result = original.call
      assignment.update!(client_management: false)
      expect(AuditLog).not_to receive(:record!)
      result
    end
    expect(QuickbooksHistory::CutoverVerificationJob).not_to receive(:perform_later)

    expect { service.call }.to raise_error(ArgumentError, /company access/)
    expect(batch.historical_import_cutover_review.reload.status).to eq("pending")
  end

  it "does not write queue-failure state or audit if revocation commits during queue transport" do
    apply_batch
    allow(QuickbooksHistory::CutoverVerificationJob).to receive(:perform_later) do
      assignment.update!(client_management: false)
      expect(AuditLog).not_to receive(:record!)
      raise "Synthetic queue failure"
    end

    expect do
      QuickbooksHistory::CutoverVerificationEnqueueService.new(batch: batch, actor: actor).call
    end.to raise_error(ArgumentError, /company access/)

    expect(batch.historical_import_cutover_review.reload).to have_attributes(status: "pending", verification_error: nil)
  end
end
