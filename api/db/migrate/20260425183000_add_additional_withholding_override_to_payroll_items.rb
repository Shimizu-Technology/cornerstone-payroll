class AddAdditionalWithholdingOverrideToPayrollItems < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_items, :additional_withholding_override, :decimal, precision: 10, scale: 2
  end
end
