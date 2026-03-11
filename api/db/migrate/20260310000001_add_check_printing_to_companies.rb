# frozen_string_literal: true

class AddCheckPrintingToCompanies < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :next_check_number, :integer, default: 1001, null: false
    add_column :companies, :check_stock_type, :string, default: "bottom_check", null: false
    # Offset calibration: positive values move text right/up, negative left/down (inches)
    add_column :companies, :check_offset_x, :decimal, precision: 5, scale: 3, default: 0.0, null: false
    add_column :companies, :check_offset_y, :decimal, precision: 5, scale: 3, default: 0.0, null: false
    # Bank info for check face display (informational — MICR pre-printed on stock)
    add_column :companies, :bank_name, :string
    add_column :companies, :bank_address, :string
  end
end
