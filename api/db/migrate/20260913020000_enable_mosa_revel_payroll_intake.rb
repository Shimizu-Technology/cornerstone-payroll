# frozen_string_literal: true

class EnableMosaRevelPayrollIntake < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE companies
      SET payroll_intake_source_types = payroll_intake_source_types || '["mosa_revel"]'::jsonb
      WHERE NOT payroll_intake_source_types @> '["mosa_revel"]'::jsonb
        AND (
          lower(trim(regexp_replace(name, '[^a-zA-Z0-9]+', ' ', 'g'))) = 'mosa'
          OR lower(trim(regexp_replace(name, '[^a-zA-Z0-9]+', ' ', 'g'))) LIKE 'mosa %'
        )
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE companies
      SET payroll_intake_source_types = payroll_intake_source_types - 'mosa_revel'
      WHERE payroll_intake_source_types @> '["mosa_revel"]'::jsonb
        AND (
          lower(trim(regexp_replace(name, '[^a-zA-Z0-9]+', ' ', 'g'))) = 'mosa'
          OR lower(trim(regexp_replace(name, '[^a-zA-Z0-9]+', ' ', 'g'))) LIKE 'mosa %'
        )
    SQL
  end
end
