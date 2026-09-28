# frozen_string_literal: true

class AddInvoiceBillingProfileLogos < ActiveRecord::Migration[8.1]
  def change
    add_column :invoice_billing_profiles, :logo_storage_key, :string
    add_column :invoice_billing_profiles, :logo_content_type, :string
    add_column :invoice_billing_profiles, :logo_sha256, :string
    add_column :invoice_billing_profiles, :logo_byte_size, :integer
    add_index :invoice_billing_profiles, :logo_storage_key, unique: true
  end
end
