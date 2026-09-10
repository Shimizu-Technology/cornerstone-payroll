class TrackPayrollBonusInputSource < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_items, :bonus_source, :string
    add_column :payroll_items, :imported_bonus, :decimal, precision: 10, scale: 2
    add_check_constraint :payroll_items, "bonus_source IS NULL OR bonus_source IN ('manual', 'mosa_revel')", name: "payroll_items_bonus_source_check"
    add_check_constraint :payroll_items, "imported_bonus IS NULL OR imported_bonus >= 0", name: "payroll_items_imported_bonus_check"
  end
end
