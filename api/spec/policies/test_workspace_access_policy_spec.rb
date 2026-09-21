# frozen_string_literal: true

require "rails_helper"

RSpec.describe TestWorkspaceAccessPolicy do
  let(:organization) { create(:organization) }
  let(:source) { create(:company, organization: organization) }
  let(:workspace) do
    create(
      :company,
      organization: organization,
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "training_replay",
      migration_source_company: source,
      migration_rehearsal_status: "ready"
    )
  end

  it "lets organization admins manage every test workspace" do
    admin = create(:user, company: source, organization: organization, role: "admin")

    expect(described_class.allowed?(user: admin, company: workspace, request_method: "POST", capability: :manage_client_configuration)).to be(true)
  end

  it "keeps reviewers read-only" do
    reviewer = create(:user, company: source, organization: organization, role: "accountant")
    CompanyAssignment.create!(user: reviewer, company: workspace, workspace_access_level: "reviewer")

    expect(described_class.allowed?(user: reviewer, company: workspace, request_method: "GET")).to be(true)
    expect(described_class.allowed?(user: reviewer, company: workspace, request_method: "PATCH")).to be(false)
  end

  it "lets operators run payroll but not change protected client configuration" do
    operator = create(:user, company: source, organization: organization, role: "accountant")
    CompanyAssignment.create!(user: operator, company: workspace, workspace_access_level: "operator")

    expect(described_class.allowed?(user: operator, company: workspace, request_method: "POST", capability: :payroll_operations)).to be(true)
    expect(described_class.allowed?(user: operator, company: workspace, request_method: "PATCH", capability: :manage_client_configuration)).to be(false)
  end

  it "keeps sealed backups read-only even for admins" do
    admin = create(:user, company: source, organization: organization, role: "admin")
    workspace.update!(test_workspace_purpose: "backup_snapshot", test_workspace_sealed_at: Time.current)

    expect(described_class.allowed?(user: admin, company: workspace, request_method: "GET")).to be(true)
    expect(described_class.allowed?(user: admin, company: workspace, request_method: "POST", capability: :payroll_operations)).to be(false)
    expect(described_class.allowed?(user: admin, company: workspace, request_method: "PATCH", capability: :manage_client_configuration)).to be(false)
    expect(described_class.allowed?(user: admin, company: workspace, request_method: "POST", capability: :manage_organization)).to be(true)
  end
end
