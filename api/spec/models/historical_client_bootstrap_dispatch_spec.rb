# frozen_string_literal: true

require "rails_helper"

RSpec.describe HistoricalClientBootstrapDispatch, type: :model do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:batch) do
    HistoricalImportBatch.create!(
      company: company,
      created_by: actor,
      source_system: "quickbooks_online",
      source_label: "Durable dispatch fixture",
      bundle_digest: SecureRandom.hex(32),
      importer_version: QuickbooksHistory::BundleParser::IMPORTER_VERSION,
      status: "previewed"
    )
  end
  let!(:bootstrap) do
    HistoricalClientBootstrap.create!(
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
