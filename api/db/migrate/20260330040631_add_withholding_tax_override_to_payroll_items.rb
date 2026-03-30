class AddWithholdingTaxOverrideToPayrollItems < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_items, :withholding_tax_override, :decimal, precision: 10, scale: 2, default: nil
  end
end
