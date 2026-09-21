# frozen_string_literal: true

class CreateTimeTrackingClassificationReconciliations < ActiveRecord::Migration[8.0]
  def change
    create_table :time_tracking_classification_reconciliations do |t|
      t.references :company, null: false, foreign_key: true
      t.references :time_tracking_source, null: false, foreign_key: true, index: { name: "idx_classification_reconciliations_source" }
      t.references :pay_period, null: false, foreign_key: true
      t.references :payroll_item, null: false, foreign_key: true, index: { unique: true, name: "idx_classification_reconciliations_item" }
      t.references :employee, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.uuid :source_user_uuid, null: false
      t.jsonb :source_entries, null: false, default: []
      t.decimal :source_regular_hours, precision: 8, scale: 2, null: false
      t.decimal :source_overtime_hours, precision: 8, scale: 2, null: false
      t.decimal :payroll_regular_hours, precision: 8, scale: 2, null: false
      t.decimal :payroll_overtime_hours, precision: 8, scale: 2, null: false
      t.decimal :gross_wage_difference, precision: 12, scale: 2, null: false
      t.string :check_number, null: false
      t.date :payment_effective_on, null: false
      t.string :status, null: false, default: "pending"
      t.text :note, null: false
      t.timestamps
    end

    add_check_constraint :time_tracking_classification_reconciliations,
                         "status IN ('pending', 'complete')",
                         name: "classification_reconciliation_status"
    add_check_constraint :time_tracking_classification_reconciliations,
                         "source_regular_hours + source_overtime_hours = payroll_regular_hours + payroll_overtime_hours",
                         name: "classification_reconciliation_total_hours"
    add_reference :time_tracking_manual_allocations, :classification_reconciliation,
                  foreign_key: { to_table: :time_tracking_classification_reconciliations },
                  index: { name: "idx_manual_allocations_classification_reconciliation" }
  end
end
