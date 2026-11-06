# frozen_string_literal: true

class EnforceCheckSupersessionRolloutApproval < ActiveRecord::Migration[8.0]
  def change
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION enforce_check_supersession_rollout_approval() RETURNS trigger AS $$
          BEGIN
            IF NOT EXISTS (
              SELECT 1 FROM companies c JOIN users u ON u.id = NEW.user_id
              WHERE c.id = NEW.company_id AND u.organization_id = c.organization_id
                AND u.active = true AND u.role IN (5, 6, 0, 1)
            ) THEN
              RAISE EXCEPTION 'Check supersession requires an active manager or administrator';
            END IF;
            IF EXISTS (SELECT 1 FROM companies WHERE id = NEW.company_id AND payroll_environment = 'live')
              AND NOT EXISTS (SELECT 1 FROM check_supersession_rollout_approvals WHERE company_id = NEW.company_id) THEN
              RAISE EXCEPTION 'Live-check supersession requires company-specific rollout approval';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER enforce_check_supersession_rollout_approval_on_insert
            BEFORE INSERT ON non_employee_check_supersessions
            FOR EACH ROW EXECUTE FUNCTION enforce_check_supersession_rollout_approval();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS enforce_check_supersession_rollout_approval_on_insert ON non_employee_check_supersessions;
          DROP FUNCTION IF EXISTS enforce_check_supersession_rollout_approval();
        SQL
      end
    end
  end
end
