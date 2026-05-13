require "rails_helper"

RSpec.describe User, type: :model do
  describe "invitation_status defaults" do
    it "uses the schema default for new records" do
      company = create(:company)

      user = User.new(
        company: company,
        email: "default-status@example.com",
        name: "Default Status",
        role: "admin",
        active: true
      )

      expect(user).to be_valid
      expect(user.invitation_status).to eq("accepted")
    end
  end

  describe "#accessible_company_ids" do
    it "scopes legacy admins to companies in their organization" do
      organization = create(:organization)
      company = create(:company, organization: organization)
      sibling_company = create(:company, organization: organization)
      foreign_company = create(:company)
      user = User.create!(
        company: company,
        organization: organization,
        email: "admin-access@example.com",
        name: "Admin",
        role: "admin",
        active: true
      )

      expect(user.accessible_company_ids).to match_array([company.id, sibling_company.id])
      expect(user.accessible_company_ids).not_to include(foreign_company.id)
    end

    it "allows super admins to access all companies" do
      company = create(:company)
      foreign_company = create(:company)
      user = User.create!(
        company: company,
        organization: company.organization,
        email: "super-admin-access@example.com",
        name: "Super Admin",
        role: "super_admin",
        active: true
      )

      expect(user.accessible_company_ids).to match_array([company.id, foreign_company.id])
    end

    it "ignores stale assignments to companies outside the user's organization" do
      organization = create(:organization)
      company = create(:company, organization: organization)
      assigned_company = create(:company, organization: organization)
      foreign_company = create(:company)
      user = create(:user, company: company, organization: organization, role: "accountant")
      CompanyAssignment.create!(user: user, company: assigned_company)
      CompanyAssignment.create!(user: user, company: foreign_company)

      expect(user.accessible_company_ids).to eq([assigned_company.id])
    end

    it "rejects users whose home company belongs to another organization" do
      company = create(:company)
      other_org = create(:organization)

      user = build(:user, company: company, organization: other_org)

      expect(user).not_to be_valid
      expect(user.errors[:company]).to include("must belong to the user's organization")
    end
  end
end
