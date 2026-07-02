# frozen_string_literal: true

class AddPayrollIntakeSourceTypesToCompanies < ActiveRecord::Migration[8.1]
  def up
    add_column :companies, :payroll_intake_source_types, :jsonb, null: false, default: []

    execute <<~SQL.squish
      UPDATE companies
      SET payroll_intake_source_types = '["spike_email"]'::jsonb
      WHERE lower(name) LIKE '%spike%'
         OR lower(name) LIKE '%coffee slut%'
         OR lower(name) IN ('scr', 'spr')
    SQL
  end

  def down
    remove_column :companies, :payroll_intake_source_types
  end
end
