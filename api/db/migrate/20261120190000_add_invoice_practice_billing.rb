# frozen_string_literal: true

class AddInvoicePracticeBilling < ActiveRecord::Migration[8.1]
  def change
    add_column :invoice_billing_profiles, :numbering_style, :string, null: false, default: "yearly"
    add_column :invoice_billing_profiles, :next_invoice_number, :integer, null: false, default: 1
    add_column :invoice_billing_profiles, :service_catalog, :jsonb, null: false, default: []
    add_column :invoice_line_items, :line_kind, :string, null: false, default: "service_fee"
    add_check_constraint :invoice_line_items, "line_kind IN ('service_fee', 'reimbursement')", name: "invoice_line_kind_valid"
    add_check_constraint :invoice_billing_profiles, "numbering_style IN ('yearly', 'continuing') AND next_invoice_number > 0", name: "invoice_numbering_valid"
  end
end
