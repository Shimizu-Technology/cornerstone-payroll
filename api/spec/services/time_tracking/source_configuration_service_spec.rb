# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::SourceConfigurationService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }

  it "saves source configuration and delegated access atomically" do
    source = described_class.new(company_id: company.id, actor: actor).save!(
      name: "AIRE",
      source_type: "aire_services",
      base_url: "https://aire.example.com",
      shared_secret: "shared-secret",
      delegation_token: "personal-token",
      active: true
    )

    expect(source).to be_persisted
    expect(source.delegation_for(actor)&.token).to eq("personal-token")
  end

  it "rolls back source changes when delegated access is invalid" do
    source = create(:time_tracking_source, company: company, source_type: "custom", active: false)

    expect do
      described_class.new(company_id: company.id, actor: actor, source: source).save!(
        name: "Changed name",
        delegation_token: "not-allowed"
      )
    end.to raise_error(ActiveRecord::RecordInvalid, /only available for AIRE Services/)

    expect(source.reload.name).not_to eq("Changed name")
    expect(TimeTrackingDelegation).not_to exist
  end

  it "deactivates another source in the same transaction" do
    active_source = create(:time_tracking_source, company: company, active: true)
    replacement = create(:time_tracking_source, company: company, active: false)

    described_class.new(company_id: company.id, actor: actor, source: replacement).save!(active: true)

    expect(active_source.reload).not_to be_active
    expect(replacement.reload).to be_active
  end
end
