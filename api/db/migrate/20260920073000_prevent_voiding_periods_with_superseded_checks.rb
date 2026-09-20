# frozen_string_literal: true

class PreventVoidingPeriodsWithSupersededChecks < ActiveRecord::Migration[8.0]
  def change
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION prevent_voiding_period_with_superseded_checks() RETURNS trigger AS $$
          BEGIN
            IF NEW.correction_status = 'voided' AND OLD.correction_status IS DISTINCT FROM 'voided'
              AND EXISTS (
                SELECT 1 FROM payroll_items p
                JOIN non_employee_check_supersessions s ON s.payroll_item_id = p.id
                WHERE p.pay_period_id = OLD.id
              ) THEN
              RAISE EXCEPTION 'A pay period with a payroll check linked to a duplicate software record cannot be voided';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER prevent_voiding_period_with_superseded_checks_on_update
            BEFORE UPDATE OF correction_status ON pay_periods
            FOR EACH ROW EXECUTE FUNCTION prevent_voiding_period_with_superseded_checks();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS prevent_voiding_period_with_superseded_checks_on_update ON pay_periods;
          DROP FUNCTION IF EXISTS prevent_voiding_period_with_superseded_checks();
        SQL
      end
    end
  end
end
