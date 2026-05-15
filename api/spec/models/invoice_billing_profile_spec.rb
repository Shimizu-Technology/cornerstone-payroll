# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceBillingProfile do
  it "clears the default flag when archived through normal saves" do
    profile = create(:invoice_billing_profile, active: true, is_default: true)

    profile.update!(active: false)

    expect(profile.reload).to have_attributes(active: false, is_default: false)
  end

  describe ".ensure_default_for!" do
    it "promotes an existing active profile when no active default exists" do
      organization = create(:organization)
      profile = create(:invoice_billing_profile, organization: organization, is_default: false)

      expect {
        described_class.ensure_default_for!(organization)
      }.not_to change(described_class, :count)

      expect(profile.reload).to be_is_default
    end

    it "clears archived defaults before promoting an active profile" do
      organization = create(:organization)
      archived_default = create(:invoice_billing_profile, organization: organization, active: false, is_default: true)
      profile = create(:invoice_billing_profile, organization: organization, is_default: false)

      result = described_class.ensure_default_for!(organization)

      expect(result).to eq(profile)
      expect(profile.reload).to be_is_default
      expect(archived_default.reload).not_to be_is_default
    end

    it "reactivates an archived org-name profile instead of creating a duplicate" do
      organization = create(:organization, name: "Cornerstone Payroll")
      profile = create(
        :invoice_billing_profile,
        organization: organization,
        name: organization.name,
        active: false,
        is_default: false
      )

      expect {
        result = described_class.ensure_default_for!(organization)

        expect(result).to eq(profile)
      }.not_to change(described_class, :count)

      expect(profile.reload).to have_attributes(active: true, is_default: true)
    end
  end
end
