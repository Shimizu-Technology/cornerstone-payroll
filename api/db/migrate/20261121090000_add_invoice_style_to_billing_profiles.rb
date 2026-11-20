# frozen_string_literal: true

# Per-sender invoice look. Every existing and new profile starts on Classic.
# Already-issued invoices are unaffected: their stored PDF artifact is the
# evidence, and their snapshot has no "style" key, so a re-render from that
# snapshot uses the legacy layout.
class AddInvoiceStyleToBillingProfiles < ActiveRecord::Migration[8.1]
  def change
    change_table :invoice_billing_profiles, bulk: true do |t|
      t.string :invoice_theme, null: false, default: "classic"
      t.string :accent_color
      t.string :logo_size, null: false, default: "medium"
      t.boolean :show_service_period, null: false, default: true
      t.boolean :show_item_column, null: false, default: true
      t.boolean :show_how_to_pay, null: false, default: true
    end

    add_check_constraint :invoice_billing_profiles,
                         "invoice_theme IN ('classic', 'modern', 'professional', 'banner')",
                         name: "invoice_billing_profile_theme_valid"
    add_check_constraint :invoice_billing_profiles,
                         "logo_size IN ('small', 'medium', 'large')",
                         name: "invoice_billing_profile_logo_size_valid"
    add_check_constraint :invoice_billing_profiles,
                         "accent_color IS NULL OR accent_color ~ '^#[0-9A-F]{6}$'",
                         name: "invoice_billing_profile_accent_color_valid"
  end
end
