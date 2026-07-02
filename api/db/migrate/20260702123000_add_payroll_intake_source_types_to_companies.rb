# frozen_string_literal: true

class AddPayrollIntakeSourceTypesToCompanies < ActiveRecord::Migration[8.1]
  def up
    add_column :companies, :payroll_intake_source_types, :jsonb, null: false, default: []

    execute <<~SQL.squish
      UPDATE companies
      SET payroll_intake_source_types = '["spike_email"]'::jsonb
      WHERE lower(trim(regexp_replace(name, '[^a-zA-Z0-9]+', ' ', 'g'))) IN (
        'spike',
        'spike coffee',
        'spike coffee roasters',
        'spike coffee roasters llc',
        'spike coffee roasters inc',
        'spike coffee roasters corporation',
        'spike coffee roasters guam',
        'spike coffee roasters coffee slut',
        'spike coffee roasters llc coffee slut',
        'spike coffee roasters inc coffee slut',
        'coffee slut',
        'coffee slut scr'
      )
    SQL
  end

  def down
    remove_column :companies, :payroll_intake_source_types
  end
end
