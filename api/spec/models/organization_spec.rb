# frozen_string_literal: true

require "rails_helper"

RSpec.describe Organization, type: :model do
  it "normalizes slugs from names" do
    organization = described_class.create!(name: "Acme Guam CPAs")

    expect(organization.slug).to eq("acme-guam-cpas")
  end

  describe "#save_company_within_client_limit!" do
    it "serializes the limit check and insert under an organization row lock" do
      organization = create(:organization, client_limit: 2)
      company = build(:company, organization: organization)

      expect(organization).to receive(:with_lock).and_call_original

      organization.save_company_within_client_limit!(company)

      expect(company).to be_persisted
    end

    it "rejects new companies when the organization has reached its client limit" do
      organization = create(:organization, client_limit: 1)
      create(:company, organization: organization)
      company = build(:company, organization: organization)

      expect {
        organization.save_company_within_client_limit!(company)
      }.to raise_error(ActiveRecord::RecordInvalid, /Client limit reached/)
      expect(company).not_to be_persisted
    end
  end
end
