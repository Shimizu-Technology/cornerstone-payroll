# frozen_string_literal: true

# Optional zero-padding for continuing invoice numbers (5 digits: 7055 ->
# "07055"). Nil keeps today's unpadded numbers. Issued invoices keep theirs.
class AddInvoiceNumberWidthToBillingProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :invoice_billing_profiles, :invoice_number_width, :integer
    add_check_constraint :invoice_billing_profiles, "invoice_number_width IS NULL OR invoice_number_width BETWEEN 1 AND 12",
                         name: "invoice_billing_profile_number_width_valid"
  end
end
