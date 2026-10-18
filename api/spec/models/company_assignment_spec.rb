# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompanyAssignment, type: :model do
  describe "organization consistency" do
    it "allows assigning a user to a client in the same organization" do
      organization = create(:organization)
      staff_company = create(:company, organization: organization)
      client_company = create(:company, organization: organization)
      user = create(:user, company: staff_company, organization: organization, role: "accountant")

      assignment = described_class.new(user: user, company: client_company)

      expect(assignment).to be_valid
    end

    it "rejects assigning a user to a client in another organization" do
      organization = create(:organization)
      staff_company = create(:company, organization: organization)
      foreign_company = create(:company)
      user = create(:user, company: staff_company, organization: organization, role: "accountant")

      assignment = described_class.new(user: user, company: foreign_company)

      expect(assignment).not_to be_valid
      expect(assignment.errors[:company]).to include("must belong to the user's organization")
    end

    it "does not treat two missing organization ids as a valid tenant match" do
      company = build(:company, organization: nil)
      user = build(:user, company: company, organization: nil, role: "accountant")

      assignment = described_class.new(user: user, company: company)

      expect(assignment).not_to be_valid
      expect(assignment.errors[:company]).to include("must belong to the user's organization")
    end
  end

  describe "test workspace access" do
    it "allows payroll staff to be assigned with an explicit access level" do
      organization = create(:organization)
      staff_company = create(:company, organization: organization)
      rehearsal = build_stubbed(:company, organization: organization, payroll_environment: "migration_rehearsal")
      accountant = create(:user, company: staff_company, organization: organization, role: "accountant")

      expect(described_class.new(user: accountant, company: rehearsal, workspace_access_level: "operator")).to be_valid
    end

    it "requires an access level for a test workspace" do
      organization = create(:organization)
      staff_company = create(:company, organization: organization)
      workspace = build_stubbed(:company, organization: organization, payroll_environment: "migration_rehearsal")
      accountant = create(:user, company: staff_company, organization: organization, role: "accountant")

      assignment = described_class.new(user: accountant, company: workspace)

      expect(assignment).not_to be_valid
      expect(assignment.errors[:workspace_access_level]).to include("is required for a test workspace")
    end

    it "rejects client portal access to a rehearsal" do
      organization = create(:organization)
      client_company = create(:company, organization: organization)
      rehearsal = build_stubbed(:company, organization: organization, payroll_environment: "migration_rehearsal")
      client = create(:user, company: client_company, organization: organization, role: "client")

      assignment = described_class.new(user: client, company: rehearsal, workspace_access_level: "operator")

      expect(assignment).not_to be_valid
      expect(assignment.errors[:company]).to include("test workspaces are available only to payroll staff")
    end

    it "does not allow workspace access levels on production clients" do
      organization = create(:organization)
      company = create(:company, organization: organization)
      accountant = create(:user, company: company, organization: organization, role: "accountant")

      assignment = described_class.new(user: accountant, company: company, workspace_access_level: "reviewer")

      expect(assignment).not_to be_valid
      expect(assignment.errors[:workspace_access_level]).to include("is only available for a test workspace")
    end
  end
end

RSpec.describe "CompanyAssignment client management integrity", type: :model do
  let(:company) { create(:company) }
  let(:accountant) { create(:user, company: company, role: "accountant") }
  let(:admin) { create(:user, company: company) }

  it "defaults new and existing ordinary assignments to no grant" do
    assignment = create(:company_assignment, user: accountant, company: company)
    expect(assignment.reload.client_management).to be(false)
    expect(CompanyAssignment.columns_hash.fetch("client_management").null).to be(false)
    expect(CompanyAssignment.columns_hash.fetch("client_management").default).to be(false)
  end

  it "requires an active administrator grantor other than the recipient" do
    assignment = build(:company_assignment, user: accountant, company: company, client_management: true, granted_by: accountant)
    expect(assignment).not_to be_valid
    assignment.granted_by = create(:user, company: company, role: "manager")
    expect(assignment).not_to be_valid
    assignment.granted_by = admin
    expect(assignment).to be_valid
    admin.update!(active: false)
    expect(assignment).not_to be_valid
  end

  it "rejects grants to other roles, expired memberships and inactive recipients" do
    assignment = build(:company_assignment, user: accountant, company: company, client_management: true, granted_by: admin)
    assignment.expires_at = 1.second.ago
    expect(assignment).not_to be_valid
    assignment.expires_at = nil
    accountant.active = false
    expect(assignment).not_to be_valid
    accountant.active = true
    accountant.role = "manager"
    expect(assignment).not_to be_valid
  end

  it "rejects null at both model and database boundaries" do
    assignment = create(:company_assignment, user: accountant, company: company)
    assignment.client_management = nil
    expect(assignment).not_to be_valid
    expect do
      CompanyAssignment.transaction(requires_new: true) { assignment.update_columns(client_management: nil) }
    end.to raise_error(ActiveRecord::NotNullViolation)
  end

  it "enforces the live grant shape even for a raw write" do
    assignment = create(:company_assignment, user: accountant, company: company, client_management: true, granted_by: admin)
    expect do
      CompanyAssignment.transaction(requires_new: true) { assignment.update_columns(workspace_access_level: "workspace_admin") }
    end.to raise_error(ActiveRecord::StatementInvalid, /company_assignments_client_management_live_shape/)
  end
end
