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
      stale_assignment = CompanyAssignment.new(user: user, company: foreign_company)
      stale_assignment.save!(validate: false)

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

  describe "primary platform owner protection" do
    let(:company) { create(:company) }
    let!(:owner) do
      User.create!(
        company: company,
        organization: company.organization,
        email: User::PRIMARY_PLATFORM_OWNER_EMAIL,
        name: "Leon",
        role: "super_admin",
        active: true,
        platform_owner: true
      )
    end

    it "cannot be demoted, deactivated, unmarked, or destroyed through the model" do
      owner.assign_attributes(role: "admin", active: false, platform_owner: false)
      expect(owner).not_to be_valid
      expect(owner.errors.full_messages.join(" ")).to include("primary platform owner")

      owner.reload
      expect(owner.destroy).to be(false)
      expect(User.exists?(owner.id)).to be(true)
    end
  end

  describe "payroll access and session revocation" do
    let(:organization) { create(:organization) }
    let(:company) { create(:company, organization: organization) }

    it "requires both the user and regular user's organization to be active" do
      user = create(:user, company: company, organization: organization, role: "admin")

      expect(user.payroll_access_allowed?).to be(true)
      organization.update_columns(status: "inactive")
      user.reload
      expect(user.payroll_access_allowed?).to be(false)
      user.update_columns(active: false)
      expect(user.reload.payroll_access_allowed?).to be(false)
    end

    it "allows only an active super admin to recover an inactive organization" do
      user = create(:user, company: company, organization: organization, role: "super_admin")
      organization.update_columns(status: "inactive")

      expect(user.reload.payroll_access_allowed?).to be(true)
      user.update_columns(active: false)
      expect(user.reload.payroll_access_allowed?).to be(false)
    end

    it "disconnects existing cable sessions after deactivation commits" do
      user = create(:user, company: company, organization: organization)
      allow(PayrollAccess::SessionRevoker).to receive(:disconnect_user)

      user.update!(active: false)

      expect(PayrollAccess::SessionRevoker).to have_received(:disconnect_user).with(user)
    end

    it "does not disconnect sessions for unrelated user updates" do
      user = create(:user, company: company, organization: organization)
      allow(PayrollAccess::SessionRevoker).to receive(:disconnect_user)

      user.update!(name: "Updated Name")

      expect(PayrollAccess::SessionRevoker).not_to have_received(:disconnect_user)
    end
  end
end
