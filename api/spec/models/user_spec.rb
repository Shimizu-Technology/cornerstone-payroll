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
end
