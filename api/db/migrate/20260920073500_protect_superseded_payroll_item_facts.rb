# frozen_string_literal: true

class ProtectSupersededPayrollItemFacts < ActiveRecord::Migration[8.0]
  def change
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_superseded_payroll_item_facts() RETURNS trigger AS $$
          BEGIN
            IF EXISTS (SELECT 1 FROM non_employee_check_supersessions WHERE payroll_item_id = OLD.id)
              AND (
                NEW.check_number IS DISTINCT FROM OLD.check_number OR
                NEW.net_pay IS DISTINCT FROM OLD.net_pay OR
                NEW.employee_id IS DISTINCT FROM OLD.employee_id OR
                NEW.pay_period_id IS DISTINCT FROM OLD.pay_period_id OR
                NEW.company_id IS DISTINCT FROM OLD.company_id OR
                NEW.payment_delivery_method IS DISTINCT FROM OLD.payment_delivery_method
              ) THEN
              RAISE EXCEPTION 'A payroll check linked to a duplicate software record cannot change verified payment facts';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER protect_superseded_payroll_item_facts_on_update
            BEFORE UPDATE OF check_number, net_pay, employee_id, pay_period_id, company_id, payment_delivery_method ON payroll_items
            FOR EACH ROW EXECUTE FUNCTION protect_superseded_payroll_item_facts();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS protect_superseded_payroll_item_facts_on_update ON payroll_items;
          DROP FUNCTION IF EXISTS protect_superseded_payroll_item_facts();
        SQL
      end
    end
  end
end
