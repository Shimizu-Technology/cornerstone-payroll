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
end
