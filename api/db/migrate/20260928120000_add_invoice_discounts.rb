# frozen_string_literal: true

class AddInvoiceDiscounts < ActiveRecord::Migration[8.0]
  def change
    add_column :invoices, :discount_type, :string, default: "none", null: false
    add_column :invoices, :discount_value, :decimal, precision: 12, scale: 2, default: 0, null: false
    add_check_constraint :invoices, "discount_type IN ('none', 'percent', 'amount')", name: "check_invoices_discount_type"
    add_check_constraint :invoices, "discount_value >= 0", name: "check_invoices_discount_value"
  end
end
