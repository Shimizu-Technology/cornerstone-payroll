# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTrackingDelegation, type: :model do
  it "encrypts the delegation token at rest" do
    delegation = create(:time_tracking_delegation, token: "plain-secret-token")

    raw_token = described_class.connection.select_value(
      "SELECT token FROM time_tracking_delegations WHERE id = #{delegation.id}"
    )

    expect(raw_token).not_to include("plain-secret-token")
    expect(delegation.reload.token).to eq("plain-secret-token")
  end

  it "allows active staff assigned to a client company" do
    home_company = create(:company)
    client_company = create(:company, organization: home_company.organization)
    user = create(:user, company: home_company, organization: home_company.organization, role: "manager")
    create(:company_assignment, user: user, company: client_company)

    delegation = build(:time_tracking_delegation, company: client_company, user: user)

    expect(delegation).to be_valid
  end

  it "rejects users without access and inactive staff" do
    company = create(:company)
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    outsider = create(:user, role: "manager")
    inactive = create(:user, company: company, organization: company.organization, role: "admin", active: false)

    expect(build(:time_tracking_delegation, company: company, time_tracking_source: source, user: outsider))
      .not_to be_valid
    expect(build(:time_tracking_delegation, company: company, time_tracking_source: source, user: inactive))
      .not_to be_valid
  end

  it "rejects a source from another company" do
    company = create(:company)
    user = create(:user, company: company, organization: company.organization, role: "admin")
    foreign_source = create(:time_tracking_source, source_type: "aire_services")

    delegation = build(
      :time_tracking_delegation,
      company: company,
      time_tracking_source: foreign_source,
      user: user
    )

    expect(delegation).not_to be_valid
    expect(delegation.errors[:time_tracking_source]).to include("must belong to the same company")
  end
end
