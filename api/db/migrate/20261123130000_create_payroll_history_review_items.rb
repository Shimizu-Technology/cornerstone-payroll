# frozen_string_literal: true

class CreatePayrollHistoryReviewItems < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"

    create_table :payroll_history_review_items do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :pay_period, foreign_key: { on_delete: :restrict }
      t.references :payroll_item, foreign_key: { on_delete: :restrict }
      t.references :employee, foreign_key: { on_delete: :restrict }
      t.references :historical_import_batch, foreign_key: { on_delete: :restrict }
      t.references :resolved_by, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :tax_year, null: false
      t.string :subject_type, null: false
      t.string :subject_digest, null: false
      t.string :status, null: false, default: "open"
      t.string :resolution_code
      t.text :resolution_reference
      t.datetime :resolved_at
      t.datetime :reopened_at
      t.timestamps

      t.index %i[company_id tax_year subject_type pay_period_id payroll_item_id historical_import_batch_id],
        name: "idx_payroll_history_review_subject", unique: true, nulls_not_distinct: true, where: "subject_type <> 'legacy_basis_gap'"
      t.index %i[company_id tax_year employee_id], name: "idx_payroll_history_review_gap", unique: true, where: "subject_type = 'legacy_basis_gap'"
      t.check_constraint <<~SQL.squish, name: "payroll_history_review_subject_shape"
        CASE
        WHEN subject_type = 'voided_pay_period' THEN pay_period_id IS NOT NULL AND num_nonnulls(payroll_item_id, employee_id, historical_import_batch_id) = 0
        WHEN subject_type IN ('reversed_payroll_item', 'legacy_disposition') THEN payroll_item_id IS NOT NULL AND employee_id IS NOT NULL AND num_nonnulls(pay_period_id, historical_import_batch_id) = 0
        WHEN subject_type = 'legacy_basis_gap' THEN employee_id IS NOT NULL AND num_nonnulls(pay_period_id, payroll_item_id, historical_import_batch_id) = 0
        WHEN subject_type = 'imported_history' THEN historical_import_batch_id IS NOT NULL AND num_nonnulls(pay_period_id, payroll_item_id, employee_id) = 0
        ELSE FALSE END
      SQL
      t.check_constraint <<~SQL.squish, name: "payroll_history_review_resolution_shape"
        (status = 'open' AND num_nonnulls(resolution_code, resolution_reference, resolved_at, resolved_by_id) = 0)
        OR (status = 'resolved' AND num_nonnulls(resolution_code, resolution_reference, resolved_at) = 3
          AND (resolved_by_id IS NOT NULL OR resolution_code = 'legacy_basis_proven')
          AND char_length(btrim(resolution_reference)) BETWEEN 10 AND 1000)
      SQL
    end
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    drop_table :payroll_history_review_items
  end
end
