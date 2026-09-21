# frozen_string_literal: true

class AddTrainingReplayLineage < ActiveRecord::Migration[8.0]
  def change
    add_reference :employees,
                  :test_workspace_source_employee,
                  foreign_key: { to_table: :employees, on_delete: :restrict },
                  index: false
    add_index :employees,
              [ :company_id, :test_workspace_source_employee_id ],
              unique: true,
              where: "test_workspace_source_employee_id IS NOT NULL",
              name: "idx_employees_training_source_unique"

    add_reference :pay_periods,
                  :test_workspace_source_pay_period,
                  foreign_key: { to_table: :pay_periods, on_delete: :restrict },
                  index: false
    add_column :pay_periods, :test_workspace_role, :string
    add_index :pay_periods,
              [ :company_id, :test_workspace_source_pay_period_id ],
              unique: true,
              where: "test_workspace_source_pay_period_id IS NOT NULL",
              name: "idx_pay_periods_training_source_unique"
    add_index :pay_periods, [ :company_id, :test_workspace_role ], name: "idx_pay_periods_training_role"
    add_check_constraint :pay_periods,
                         "test_workspace_role IS NULL OR test_workspace_role IN ('baseline', 'practice')",
                         name: "pay_periods_test_workspace_role_check"
    add_check_constraint :pay_periods,
                         "(test_workspace_role IS NULL) = (test_workspace_source_pay_period_id IS NULL)",
                         name: "pay_periods_training_lineage_complete"
  end
end
