class CreateQuarterlyComplianceWorkflow < ActiveRecord::Migration[8.1]
  def change
    create_table :quarterly_compliance_packets do |t|
      t.references :company, null: false, foreign_key: true
      t.integer :year, null: false
      t.integer :quarter, null: false
      t.string :status, null: false, default: "not_started"
      t.date :official_due_date, null: false
      t.date :internal_target_date, null: false
      t.references :assigned_to, foreign_key: { to_table: :users }
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at
      t.text :notes
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :quarterly_compliance_packets, [ :company_id, :year, :quarter ], unique: true, name: "idx_qc_packets_company_year_quarter"
    add_check_constraint :quarterly_compliance_packets, "quarter BETWEEN 1 AND 4", name: "qc_packets_quarter_check"

    create_table :quarterly_compliance_tasks do |t|
      t.references :quarterly_compliance_packet, null: false, foreign_key: true, index: { name: "idx_qc_tasks_packet" }
      t.string :task_type, null: false
      t.string :status, null: false, default: "not_started"
      t.date :due_date
      t.date :internal_target_date
      t.references :assigned_to, foreign_key: { to_table: :users }
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at
      t.datetime :filed_at
      t.datetime :paid_at
      t.decimal :payment_amount, precision: 12, scale: 2
      t.string :filing_confirmation_number
      t.string :payment_confirmation_number
      t.boolean :proof_attached, null: false, default: false
      t.text :notes
      t.jsonb :data, null: false, default: {}
      t.timestamps
    end

    add_index :quarterly_compliance_tasks, [ :quarterly_compliance_packet_id, :task_type ], unique: true, name: "idx_qc_tasks_packet_type"
  end
end
