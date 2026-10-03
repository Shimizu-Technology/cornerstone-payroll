# frozen_string_literal: true

class CreateNonEmployeeCheckSupersessions < ActiveRecord::Migration[8.0]
  def change
    create_table :non_employee_check_supersessions do |t|
      t.references :non_employee_check, null: false, foreign_key: true, index: { unique: true }
      t.references :payroll_item, null: false, foreign_key: true, index: { unique: true }
      t.references :user, null: false, foreign_key: true
      t.text :reason, null: false
      t.datetime :created_at, null: false
    end

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_non_employee_check_supersession() RETURNS trigger AS $$
          BEGIN
            RAISE EXCEPTION 'Non-employee check supersession evidence is append-only';
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER protect_non_employee_check_supersessions
            BEFORE UPDATE OR DELETE ON non_employee_check_supersessions
            FOR EACH ROW EXECUTE FUNCTION protect_non_employee_check_supersession();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS protect_non_employee_check_supersessions ON non_employee_check_supersessions;
          DROP FUNCTION IF EXISTS protect_non_employee_check_supersession();
        SQL
      end
    end
  end
end
