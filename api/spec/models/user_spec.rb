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
    it "memoizes the super-admin company lookup" do
      company = create(:company)
      user = User.create!(
        company: company,
        email: "super-admin-access@example.com",
        name: "Super Admin",
        role: "admin",
        active: true,
        super_admin: true
      )

      expect(Company).to receive(:ids).once.and_return([company.id])

      2.times { expect(user.accessible_company_ids).to eq([company.id]) }
    end
  end
end
