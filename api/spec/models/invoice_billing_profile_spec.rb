# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceBillingProfile do
  describe "invoice style" do
    it "starts on Classic with the theme color, a medium logo and every section shown" do
      profile = create(:invoice_billing_profile)

      expect(profile).to have_attributes(invoice_theme: "classic", accent_color: nil, logo_size: "medium",
                                         show_service_period: true, show_item_column: true, show_how_to_pay: true)
      expect(profile.invoice_style.accent_hex).to eq("#1F4E79")
    end

    it "normalizes a hex accent and rejects anything else" do
      profile = create(:invoice_billing_profile)

      profile.update!(accent_color: " 0f766e ")
      expect(profile.accent_color).to eq("#0F766E")
      profile.update!(accent_color: "")
      expect(profile.accent_color).to be_nil

      %w[#12345 #GGGGGG blue #1234567 rgb(0,0,0)].each do |value|
        profile.accent_color = value
        expect(profile).not_to be_valid, value
        expect(profile.errors[:accent_color]).to include("must be a hex color like #1F4E79")
      end
    end

    it "accepts only the four themes and three logo sizes" do
      profile = build(:invoice_billing_profile, invoice_theme: "neon", logo_size: "huge")

      expect(profile).not_to be_valid
      expect(profile.errors[:invoice_theme]).to be_present
      expect(profile.errors[:logo_size]).to be_present
      saved = create(:invoice_billing_profile)
      { invoice_theme: "neon", accent_color: "#abcdef" }.each do |column, value|
        expect { described_class.transaction(requires_new: true) { saved.update_columns(column => value) } }
          .to raise_error(ActiveRecord::StatementInvalid, /check constraint/)
      end
    end
  end

  it "clears the default flag when archived through normal saves" do
    profile = create(:invoice_billing_profile, active: true, is_default: true)

    profile.update!(active: false)

    expect(profile.reload).to have_attributes(active: false, is_default: false)
  end

  describe ".ensure_default_for!" do
    it "refreshes only the previous generated footer on an existing default" do
      organization = create(:organization)
      legacy = create(:invoice_billing_profile, organization: organization, is_default: true,
                       footer_note: described_class::LEGACY_DEFAULT_FOOTER)

      expect(described_class.ensure_default_for!(organization)).to eq(legacy)
      expect(legacy.reload.footer_note).to eq(described_class::DEFAULT_FOOTER)

      legacy.update!(footer_note: "Custom remittance note")
      described_class.ensure_default_for!(organization)
      expect(legacy.reload.footer_note).to eq("Custom remittance note")
    end

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
