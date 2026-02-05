class AddStandardDeductionToTaxTables < ActiveRecord::Migration[8.1]
  def change
    add_column :tax_tables, :standard_deduction, :decimal, precision: 10, scale: 2, default: 0
  end
end
