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

  describe "cable session revocation" do
    it "disconnects regular users but preserves super-admin recovery sessions after deactivation" do
      organization = create(:organization)
      company = create(:company, organization: organization)
      regular_user = create(:user, company: company, organization: organization, role: "admin")
      super_admin = create(:user, company: company, organization: organization, role: "super_admin")
      allow(PayrollAccess::RevocationDispatcher).to receive(:call)

      organization.update!(status: "inactive")

      expect(PayrollAccess::RevocationDispatcher).to have_received(:call).with(regular_user)
      expect(PayrollAccess::RevocationDispatcher).not_to have_received(:call).with(super_admin)
    end

    it "does not disconnect users for unrelated organization updates" do
      organization = create(:organization)
      company = create(:company, organization: organization)
      create(:user, company: company, organization: organization)
      allow(PayrollAccess::RevocationDispatcher).to receive(:call)

      organization.update!(name: "Renamed Organization")

      expect(PayrollAccess::RevocationDispatcher).not_to have_received(:call)
    end
  end
end
