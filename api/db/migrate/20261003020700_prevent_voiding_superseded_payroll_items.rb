# frozen_string_literal: true

class PreventVoidingSupersededPayrollItems < ActiveRecord::Migration[8.0]
  def change
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION prevent_voiding_superseded_payroll_item() RETURNS trigger AS $$
          BEGIN
            IF NEW.voided = true AND OLD.voided = false
              AND EXISTS (SELECT 1 FROM non_employee_check_supersessions WHERE payroll_item_id = OLD.id) THEN
              RAISE EXCEPTION 'A payroll check linked to a duplicate software record cannot be voided';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER prevent_voiding_superseded_payroll_item_on_update
            BEFORE UPDATE OF voided ON payroll_items
            FOR EACH ROW EXECUTE FUNCTION prevent_voiding_superseded_payroll_item();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS prevent_voiding_superseded_payroll_item_on_update ON payroll_items;
          DROP FUNCTION IF EXISTS prevent_voiding_superseded_payroll_item();
        SQL
      end
    end
  end
end
