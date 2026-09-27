class CreatePayrollItemLegacyDispositions < ActiveRecord::Migration[8.0]
  def change
    create_table :payroll_item_legacy_dispositions do |t|
      t.references :payroll_item, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :created_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :reason, null: false
      t.string :evidence_digest, null: false
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end
  end
end
