# frozen_string_literal: true

# M4-9d: what the employee service reports about itself. The staff switch
# screen runs on Payroll web, which can't read the employee service's process
# settings, so the employee service records them (one row per service) when
# its dependency health check runs.
class CreateEmployeeServiceObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_service_observations do |t|
      t.string :service, null: false, limit: 40
      t.datetime :observed_at, null: false
      t.string :revision, limit: 80
      t.string :process_role, null: false, limit: 40
      t.string :rls_guard_mode, null: false, limit: 10
      t.boolean :rls_runtime_role_verified, null: false, default: false
      t.boolean :require_mfa, null: false, default: false
      t.boolean :mfa_evidence_recorded, null: false, default: false
      t.boolean :authorized_parties_valid, null: false, default: false
      t.boolean :dependencies_healthy, null: false, default: false
      t.boolean :service_checks_passed, null: false, default: false
      t.jsonb :failed_checks, null: false, default: []
      t.timestamps null: false

      t.index :service, unique: true, name: "idx_employee_service_observations_service"
      t.check_constraint "service IN ('employee_web')", name: "employee_service_observations_service_check"
      t.check_constraint "rls_guard_mode IN ('off', 'log', 'raise')", name: "employee_service_observations_guard_mode_check"
      t.check_constraint "jsonb_typeof(failed_checks) = 'array'", name: "employee_service_observations_failed_checks_check"
    end
  end
end
