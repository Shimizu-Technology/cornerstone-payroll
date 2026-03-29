class AddSalaryOverrideAndNonTaxablePayToPayrollItems < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_items, :salary_override, :decimal, precision: 12, scale: 2
    add_column :payroll_items, :non_taxable_pay, :decimal, precision: 12, scale: 2, default: 0.0
  end
end
