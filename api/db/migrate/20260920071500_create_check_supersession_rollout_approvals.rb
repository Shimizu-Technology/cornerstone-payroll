# frozen_string_literal: true

class CreateCheckSupersessionRolloutApprovals < ActiveRecord::Migration[8.0]
  def change
    create_table :check_supersession_rollout_approvals do |t|
      t.references :company, null: false, foreign_key: true, index: { unique: true }
      t.references :approved_by, null: false, foreign_key: { to_table: :users }
      t.text :reason, null: false
      t.datetime :approved_at, null: false
      t.datetime :created_at, null: false
    end

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_check_supersession_rollout_approval() RETURNS trigger AS $$
          BEGIN
            IF TG_OP <> 'INSERT' THEN
              RAISE EXCEPTION 'Check supersession rollout approvals are append-only';
            END IF;
            IF NOT EXISTS (
              SELECT 1 FROM companies c JOIN users u ON u.id = NEW.approved_by_id
              WHERE c.id = NEW.company_id AND c.payroll_environment = 'live'
                AND u.organization_id = c.organization_id AND u.active = true
                AND u.role IN (5, 6)
            ) OR length(btrim(NEW.reason)) < 20 THEN
              RAISE EXCEPTION 'Live-check rollout approval requires an active organization administrator and documented reason';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER protect_check_supersession_rollout_approvals
            BEFORE INSERT OR UPDATE OR DELETE ON check_supersession_rollout_approvals
            FOR EACH ROW EXECUTE FUNCTION protect_check_supersession_rollout_approval();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS protect_check_supersession_rollout_approvals ON check_supersession_rollout_approvals;
          DROP FUNCTION IF EXISTS protect_check_supersession_rollout_approval();
        SQL
      end
    end
  end
end
