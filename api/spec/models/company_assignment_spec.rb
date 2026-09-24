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
