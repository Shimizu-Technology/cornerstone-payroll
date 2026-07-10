# frozen_string_literal: true

class AddSimplePayrollRegisterToCompanies < ActiveRecord::Migration[8.1]
  def up
    add_column :companies, :simple_payroll_register_enabled, :boolean, null: false, default: false

    execute <<~SQL.squish
      UPDATE companies
      SET simple_payroll_register_enabled = TRUE
      WHERE payroll_intake_source_types @> '["spike_email"]'::jsonb
         OR lower(trim(regexp_replace(name, '[^a-zA-Z0-9]+', ' ', 'g'))) IN (
           'aire',
           'aire services',
           'aire services llc',
           'aire services inc',
           'aire services corporation'
         )
    SQL
  end

  def down
    remove_column :companies, :simple_payroll_register_enabled
  end
end
