# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::CutoverReviewService do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:batch) do
    HistoricalImportBatch.create!(
      company: company,
      source_label: "Reviewed QuickBooks history",
      bundle_digest: SecureRandom.hex(32),
      importer_version: "test",
      status: "applied"
    )
  end
  let!(:review) do
    HistoricalImportCutoverReview.create!(
      company: company,
      historical_import_batch: batch,
      status: "verified",
      evidence: {
        "passed" => true,
        "exceptions" => [ { "key" => "opening", "message" => "Opening summary limitation" } ]
      },
      evidence_digest: "a" * 64,
      verified_at: Time.current,
      verified_by: actor
    )
  end

  it "requires every exception and operational attestation before sealing approval" do
    service = described_class.new(review: review, actor: actor)
    service.save!(
      exception_dispositions: { opening: "Accepted because retained totals reconcile." },
      attestations: HistoricalImportCutoverReview::ATTESTATIONS.keys.index_with(true),
      approval_notes: "No remaining limitations."
    )
    expect(review.reload).to be_ready_for_approval

    expect { service.approve!(acknowledgement: "yes") }.to raise_error(ArgumentError, /acknowledgement/)
    service.approve!(acknowledgement: HistoricalImportCutoverReview::APPROVAL_ACKNOWLEDGEMENT)

    expect(review.reload.status).to eq("approved")
    expect(review.approved_by).to eq(actor)
    expect(review.update(approval_notes: "Changed")).to be(false)
    expect(review.errors.full_messages).to include("Approved cutover reviews cannot be changed")
    expect(review.destroy).to be(false)
    expect(review.errors.full_messages).to include("Cutover review evidence cannot be deleted")
  end

  it "rejects approval while an exception or attestation remains incomplete" do
    service = described_class.new(review: review, actor: actor)
    service.save!(exception_dispositions: {}, attestations: {}, approval_notes: "Pending review.")

    expect(review.reload).not_to be_ready_for_approval
    expect do
      service.approve!(acknowledgement: HistoricalImportCutoverReview::APPROVAL_ACKNOWLEDGEMENT)
    end.to raise_error(ArgumentError, /Complete every cutover check/)
  end

  it "rejects approval if the historical import no longer remains applied" do
    service = described_class.new(review: review, actor: actor)
    service.save!(
      exception_dispositions: { opening: "Accepted because retained totals reconcile." },
      attestations: HistoricalImportCutoverReview::ATTESTATIONS.keys.index_with(true),
      approval_notes: "No remaining limitations."
    )
    batch.update_column(:status, "previewed")

    expect do
      service.approve!(acknowledgement: HistoricalImportCutoverReview::APPROVAL_ACKNOWLEDGEMENT)
    end.to raise_error(ArgumentError, /must remain applied/)
  end

  it "rolls back review edits when their audit record cannot be written" do
    original_notes = review.approval_notes
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordInvalid)

    expect do
      described_class.new(review: review, actor: actor).save!(
        exception_dispositions: { opening: "Accepted because retained totals reconcile." },
        attestations: HistoricalImportCutoverReview::ATTESTATIONS.keys.index_with(true),
        approval_notes: "This must not survive without its audit record."
      )
    end.to raise_error(ActiveRecord::RecordInvalid)

    expect(review.reload).to have_attributes(
      exception_dispositions: {},
      attestations: {},
      approval_notes: original_notes
    )
  end

  it "rolls back approval when its audit record cannot be written" do
    service = described_class.new(review: review, actor: actor)
    service.save!(
      exception_dispositions: { opening: "Accepted because retained totals reconcile." },
      attestations: HistoricalImportCutoverReview::ATTESTATIONS.keys.index_with(true),
      approval_notes: "No remaining limitations."
    )
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordInvalid)

    expect do
      service.approve!(acknowledgement: HistoricalImportCutoverReview::APPROVAL_ACKNOWLEDGEMENT)
    end.to raise_error(ActiveRecord::RecordInvalid)

    expect(review.reload).to have_attributes(status: "verified", approved_at: nil, approved_by_id: nil)
  end
end
