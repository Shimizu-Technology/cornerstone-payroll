# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceBillingProfile do
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
  end
end
