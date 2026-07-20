# frozen_string_literal: true

class CreatePayrollLiabilitySettlementLedger < ActiveRecord::Migration[8.0]
  def change
    create_table :payroll_liability_due_dates do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :pay_period, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.string :category, null: false
      t.string :authority, null: false
      t.date :due_date, null: false
      t.references :updated_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :payroll_liability_due_dates,
      [ :pay_period_id, :category, :authority ],
      unique: true,
      name: "idx_liability_due_dates_unique_obligation"
    add_index :payroll_liability_due_dates, [ :company_id, :due_date ], name: "idx_liability_due_dates_company_due"

    create_table :payroll_liability_payments do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :pay_period, null: false, foreign_key: { on_delete: :restrict }
      t.references :source_payment,
        foreign_key: { to_table: :payroll_liability_payments, on_delete: :restrict },
        index: false
      t.references :recorded_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :payment_type, null: false, default: "settlement"
      t.string :authority, null: false
      t.string :category, null: false
      t.decimal :amount, precision: 14, scale: 2, null: false
      t.date :payment_date, null: false
      t.string :payment_method, null: false
      t.string :confirmation_number
      t.text :notes
      t.text :reason
      t.string :idempotency_key, null: false
      t.datetime :recorded_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :payroll_liability_payments, :idempotency_key, unique: true, name: "idx_liability_payments_idempotency"
    add_index :payroll_liability_payments, :source_payment_id,
      unique: true,
      where: "source_payment_id IS NOT NULL",
      name: "idx_liability_payments_one_reversal"
    add_index :payroll_liability_payments, [ :company_id, :payment_date ], name: "idx_liability_payments_company_date"
    add_index :payroll_liability_payments, [ :pay_period_id, :authority, :category ], name: "idx_liability_payments_obligation"
    add_check_constraint :payroll_liability_payments,
      "payment_type IN ('settlement', 'reversal')",
      name: "liability_payments_type_check"
    add_check_constraint :payroll_liability_payments,
      "(payment_type = 'settlement' AND amount > 0 AND source_payment_id IS NULL) OR (payment_type = 'reversal' AND amount < 0 AND source_payment_id IS NOT NULL)",
      name: "liability_payments_sign_source_check"

    create_table :payroll_liability_allocations do |t|
      t.references :payroll_liability_payment, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.references :payroll_liability_entry, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.decimal :amount, precision: 14, scale: 2, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :payroll_liability_allocations,
      [ :payroll_liability_payment_id, :payroll_liability_entry_id ],
      unique: true,
      name: "idx_liability_allocations_unique_entry"
    add_index :payroll_liability_allocations, :payroll_liability_entry_id, name: "idx_liability_allocations_entry"
    add_check_constraint :payroll_liability_allocations, "amount <> 0", name: "liability_allocations_nonzero"

    create_table :payroll_liability_evidences do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :payroll_liability_payment, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :storage_key, null: false
      t.string :filename, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.string :sha256, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :payroll_liability_evidences, :storage_key, unique: true
    add_index :payroll_liability_evidences, :payroll_liability_payment_id, name: "idx_liability_evidence_payment"
    add_check_constraint :payroll_liability_evidences, "byte_size > 0", name: "liability_evidence_byte_size_positive"
    add_check_constraint :payroll_liability_evidences, "char_length(sha256) = 64", name: "liability_evidence_sha256_length"
  end
end
