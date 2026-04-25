class AddWithholdingTaxAdjustmentToPayrollItems < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_items, :withholding_tax_adjustment, :decimal, precision: 10, scale: 2
  end
end
