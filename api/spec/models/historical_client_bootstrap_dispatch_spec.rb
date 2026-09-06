# frozen_string_literal: true

require "rails_helper"

RSpec.describe HistoricalClientBootstrapDispatch, type: :model do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:batch) do
    create(
      :historical_import_batch,
      company: company,
      created_by: actor,
      source_label: "Durable dispatch fixture",
      status: "previewed"
    )
  end
  let!(:bootstrap) do
    create(
      :historical_client_bootstrap,
      company: company,
      historical_import_batch: batch,
      created_by: actor,
      status: "pending",
      plan_digest: SecureRandom.hex(32),
      apply_started_at: Time.current
    )
  end

  it "seals a superseded attempt instead of dispatching it" do
    dispatch = described_class.create!(
      historical_client_bootstrap: bootstrap,
      requested_by: actor,
      attempt_token: bootstrap.apply_started_at.iso8601(6)
    )
    bootstrap.update_columns(apply_started_at: 1.second.from_now)

    expect { dispatch.dispatch! }.not_to have_enqueued_job(QuickbooksHistory::ClientBootstrapJob)
    expect(dispatch.reload.completed_at).to be_present
  end

  it "seals a dispatch whose requesting user is unavailable" do
    dispatch = described_class.create!(
      historical_client_bootstrap: bootstrap,
      requested_by: nil,
      attempt_token: bootstrap.apply_started_at.iso8601(6)
    )

    expect { dispatch.dispatch! }.not_to have_enqueued_job(QuickbooksHistory::ClientBootstrapJob)

    expect(dispatch.reload).to have_attributes(
      completed_at: be_present,
      dispatch_attempts: 1,
      last_error: described_class::MISSING_REQUESTER_ERROR
    )
    expect(bootstrap.reload).to have_attributes(
      status: "failed",
      apply_error: described_class::MISSING_REQUESTER_ERROR
    )
    expect(described_class.due_for_dispatch).not_to include(dispatch)
  end

  it "does not allow durable dispatch evidence to be deleted" do
    dispatch = described_class.create!(
      historical_client_bootstrap: bootstrap,
      requested_by: actor,
      attempt_token: bootstrap.apply_started_at.iso8601(6)
    )

    expect(dispatch.destroy).to be(false)
    expect(dispatch.errors[:base]).to include("Client bootstrap dispatch evidence cannot be deleted")
  end
end
