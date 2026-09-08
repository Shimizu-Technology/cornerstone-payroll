# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollGoLiveReviewService do
  let(:company) { create(:company) }
  let(:source_company) { create(:company, organization: company.organization) }
  let(:batch) { create(:historical_import_batch, company:, status: "locked") }
  let(:technical_actor) { create(:user, company:, organization: company.organization, role: "super_admin") }
  let(:operations_actor) { create(:user, company:, organization: company.organization, role: "org_admin") }
  let(:review) do
    PayrollGoLiveReview.create!(
      company:, source_company:, historical_import_batch: batch, created_by: technical_actor,
      effective_on: Date.new(2026, 9, 21), plan_digest: "b" * 64, status: "setup_applied",
      setup_applied_at: Time.current, setup_applied_by: technical_actor,
      attestations: PayrollGoLiveReview::ATTESTATIONS.keys.index_with(true), review_notes: "Two clean parallel runs; QuickBooks fallback owner assigned."
    )
  end

  before do
    allow(review).to receive(:ready_for_signoff?).and_return(true)
  end

  it "requires two different authorized people and seals the evidence after both sign" do
    described_class.new(review:, actor: technical_actor).sign_technical!(
      acknowledgement: PayrollGoLiveReview::TECHNICAL_ACKNOWLEDGEMENT
    )

    expect do
      described_class.new(review:, actor: technical_actor).sign_operations!(
        acknowledgement: PayrollGoLiveReview::OPERATIONS_ACKNOWLEDGEMENT
      )
    end.to raise_error(ArgumentError, /manager or administrator/)

    described_class.new(review:, actor: operations_actor).sign_operations!(
      acknowledgement: PayrollGoLiveReview::OPERATIONS_ACKNOWLEDGEMENT
    )

    expect(review.reload).to have_attributes(
      status: "approved",
      technical_signed_by_id: technical_actor.id,
      operations_signed_by_id: operations_actor.id
    )
    expect { review.update!(review_notes: "Changed") }.to raise_error(ActiveRecord::RecordNotSaved)
    expect(review.errors.full_messages).to include("Approved go-live evidence cannot be changed")
  end
end
