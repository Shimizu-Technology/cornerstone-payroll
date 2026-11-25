# frozen_string_literal: true

# M4-9d: the record that the Employee app switch turned a part on for a
# company after its readiness checks passed. CompanyFeatures counts a part on
# only while its profile flag is on AND an unrevoked activation exists, so a
# direct profile write (or a future-dated row) never opens anything. Only the
# switch service writes these rows; turning a part off revokes its row.
#
# Also the durable queue of Clerk revocations the demo kill switch requests
# (pending sign-up invitations and employee sessions). Each row is retried
# until Clerk confirms, and a repeat stop never queues a duplicate.
class CreateEmployeeAppActivations < ActiveRecord::Migration[8.1]
  PARTS = %w[
    employee_portal_enabled subdomain_enabled employee_portal.features.stubs employee_portal.features.tax_forms
    employee_portal.features.profile_requests employee_portal.features.delivery_consent
  ].freeze

  def up
    create_table :employee_app_activations do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.string :part, null: false, limit: 80
      t.datetime :activated_at, null: false
      t.references :activated_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }, index: true
      t.jsonb :checks, null: false, default: []
      t.references :early_access_window, foreign_key: { to_table: :employee_app_early_access_windows, on_delete: :restrict },
        index: true
      t.datetime :revoked_at
      t.references :revoked_by, foreign_key: { to_table: :users, on_delete: :restrict }, index: true
      t.string :revoke_reason, limit: 500
      t.timestamps null: false

      t.index %i[company_id part], unique: true, where: "revoked_at IS NULL", name: "idx_employee_app_activations_open"
      t.index %i[company_id activated_at id], name: "idx_employee_app_activations_history"
      t.check_constraint "part IN (#{PARTS.map { |part| "'#{part}'" }.join(', ')})", name: "employee_app_activations_part_check"
      t.check_constraint "jsonb_typeof(checks) = 'array'", name: "employee_app_activations_checks_check"
      t.check_constraint "(revoked_at IS NULL AND revoked_by_id IS NULL AND revoke_reason IS NULL) OR " \
        "(revoked_at IS NOT NULL AND length(btrim(revoke_reason)) > 0)", name: "employee_app_activations_revoke_shape_check"
    end

    create_table :employee_app_clerk_revocations do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }, index: true
      t.references :company, null: false, foreign_key: { on_delete: :restrict }, index: true
      t.string :kind, null: false, limit: 20
      # A Clerk invitation id, or a Payroll user id for a sessions revocation.
      t.string :target, null: false, limit: 255
      t.references :user, foreign_key: { on_delete: :restrict }, index: true
      t.string :source, null: false, limit: 40
      t.datetime :requested_at, null: false
      t.references :requested_by, foreign_key: { to_table: :users, on_delete: :restrict }, index: true
      t.integer :attempts, null: false, default: 0
      t.string :last_error, limit: 200
      t.datetime :confirmed_at
      t.datetime :gave_up_at
      t.timestamps null: false

      t.index %i[kind target], unique: true, where: "confirmed_at IS NULL AND gave_up_at IS NULL",
        name: "idx_employee_app_clerk_revocations_pending"
      t.check_constraint "kind IN ('invitation', 'sessions')", name: "employee_app_clerk_revocations_kind_check"
      t.check_constraint "attempts >= 0", name: "employee_app_clerk_revocations_attempts_check"
      t.check_constraint "NOT (confirmed_at IS NOT NULL AND gave_up_at IS NOT NULL)",
        name: "employee_app_clerk_revocations_outcome_check"
    end

    execute <<~SQL
      CREATE OR REPLACE FUNCTION protect_employee_app_activation() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'employee_app_activations rows are kept for the audit history'
            USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.company_id IS DISTINCT FROM OLD.company_id
          OR NEW.part IS DISTINCT FROM OLD.part
          OR NEW.activated_at IS DISTINCT FROM OLD.activated_at
          OR NEW.activated_by_id IS DISTINCT FROM OLD.activated_by_id
          OR NEW.checks IS DISTINCT FROM OLD.checks
          OR NEW.early_access_window_id IS DISTINCT FROM OLD.early_access_window_id
          OR NEW.created_at IS DISTINCT FROM OLD.created_at
          OR OLD.revoked_at IS NOT NULL
        THEN
          RAISE EXCEPTION 'employee_app_activations rows can only be revoked once; activate again instead'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS employee_app_activations_immutable ON employee_app_activations;
      CREATE TRIGGER employee_app_activations_immutable
      BEFORE UPDATE OR DELETE ON employee_app_activations
      FOR EACH ROW
      EXECUTE FUNCTION protect_employee_app_activation();
    SQL
  end

  def down
    drop_table :employee_app_clerk_revocations
    drop_table :employee_app_activations
    execute "DROP FUNCTION IF EXISTS protect_employee_app_activation()"
  end
end
