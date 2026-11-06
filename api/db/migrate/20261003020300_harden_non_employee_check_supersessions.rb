# frozen_string_literal: true

class HardenNonEmployeeCheckSupersessions < ActiveRecord::Migration[8.0]
  def change
    add_reference :non_employee_check_supersessions, :company, foreign_key: true
    add_column :non_employee_check_supersessions, :verified_facts, :jsonb, null: false, default: {}
    reversible do |direction|
      direction.up do
        execute <<~SQL
          UPDATE non_employee_check_supersessions s
          SET company_id = c.company_id,
              verified_facts = jsonb_build_object('legacy_link_before_snapshot', true)
          FROM non_employee_checks c WHERE s.non_employee_check_id = c.id
        SQL
      end
    end
    change_column_null :non_employee_check_supersessions, :company_id, false

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION validate_non_employee_check_supersession_tenant() RETURNS trigger AS $$
          BEGIN
            IF NOT EXISTS (
              SELECT 1 FROM non_employee_checks c
              JOIN payroll_items p ON p.id = NEW.payroll_item_id
              JOIN companies co ON co.id = c.company_id
              JOIN users u ON u.id = NEW.user_id
              WHERE c.id = NEW.non_employee_check_id
                AND c.company_id = NEW.company_id
                AND p.company_id = NEW.company_id
                AND u.organization_id = co.organization_id
            ) THEN
              RAISE EXCEPTION 'Supersession records must belong to the same company and reviewer organization';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER validate_non_employee_check_supersession_tenant_on_insert
            BEFORE INSERT ON non_employee_check_supersessions
            FOR EACH ROW EXECUTE FUNCTION validate_non_employee_check_supersession_tenant();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS validate_non_employee_check_supersession_tenant_on_insert ON non_employee_check_supersessions;
          DROP FUNCTION IF EXISTS validate_non_employee_check_supersession_tenant();
        SQL
      end
    end
  end
end
