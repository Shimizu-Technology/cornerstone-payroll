# frozen_string_literal: true

# Client profitability (docs/CLIENT_PROFITABILITY.md): hours pulled from
# Cornerstone Tax's Work Hours v1 feed, the mapping of Tax clients and staff to
# Payroll records, and one settings row per organization. No pay data comes
# from Tax; cost is computed in Payroll from the practice company's payroll.
class CreateClientProfitability < ActiveRecord::Migration[8.1]
  def change
    create_table :client_profitability_settings do |t|
      t.references :organization, null: false, foreign_key: true, index: { unique: true }
      t.references :practice_company, foreign_key: { to_table: :companies, on_delete: :nullify }
      t.references :finance_book, foreign_key: { on_delete: :nullify }
      t.jsonb :tax_prep_service_names, null: false, default: []
      t.references :updated_by, foreign_key: { to_table: :users }
      t.timestamps
    end

    create_table :work_hour_imports do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :requested_by, foreign_key: { to_table: :users }
      t.date :range_start, null: false
      t.date :range_end, null: false
      t.string :status, null: false, default: "queued"
      t.string :trigger, null: false, default: "manual"
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :row_count, null: false, default: 0
      t.decimal :total_hours, precision: 12, scale: 2, null: false, default: 0
      t.integer :pending_entries, null: false, default: 0
      t.integer :denied_entries, null: false, default: 0
      t.integer :open_clock_entries, null: false, default: 0
      t.string :schema_version
      t.datetime :source_generated_at
      t.string :error_code
      t.text :error_message
      # The worker currently allowed to run this import, and until when. A
      # worker renews the lease while fetching; only the holder of claim_token
      # may commit rows (TaxWorkHours::Importer).
      t.string :claim_token
      t.datetime :lease_expires_at
      t.timestamps
      t.index [ :organization_id, :created_at ]
      # At most one queued or running import per organization, for manual and
      # nightly refreshes alike (WorkHourImport.reserve!).
      t.index :organization_id, unique: true, where: "status IN ('queued', 'running')", name: "index_work_hour_imports_one_active_per_organization"
      t.check_constraint "status IN ('queued', 'running', 'succeeded', 'failed')", name: "work_hour_import_status_valid"
      t.check_constraint "trigger IN ('manual', 'scheduled')", name: "work_hour_import_trigger_valid"
      t.check_constraint "range_end >= range_start", name: "work_hour_import_range_order"
    end

    create_table :work_hour_rows do |t|
      t.references :organization, null: false, foreign_key: true, index: false
      t.references :work_hour_import, null: false, foreign_key: true
      t.bigint :tax_user_id, null: false
      t.string :email
      t.date :work_date, null: false
      t.bigint :tax_client_id
      t.string :client_name, null: false
      t.string :system_kind
      t.boolean :unassigned, null: false, default: false
      t.bigint :category_id
      t.string :category
      t.bigint :task_id
      t.string :task
      t.string :period_type
      t.date :period_start
      t.string :period_label
      t.decimal :hours, precision: 10, scale: 2, null: false
      t.integer :minutes, null: false, default: 0
      t.jsonb :entry_ids, null: false, default: []
      t.string :approval_state, null: false
      t.timestamps
      t.index [ :organization_id, :work_date ]
      t.index [ :organization_id, :tax_client_id ]
      t.index [ :organization_id, :tax_user_id ]
      t.check_constraint "approval_state IN ('approved', 'clock', 'pending')", name: "work_hour_row_approval_state_valid"
    end

    create_table :work_hour_client_links do |t|
      t.references :organization, null: false, foreign_key: true, index: false
      t.bigint :tax_client_id, null: false
      t.string :tax_client_name
      t.string :disposition, null: false
      t.references :company, foreign_key: { on_delete: :cascade }
      t.boolean :active, null: false, default: true
      t.references :linked_by, foreign_key: { to_table: :users }
      t.timestamps
      t.index [ :organization_id, :tax_client_id ], unique: true
      t.check_constraint "(disposition = 'company' AND company_id IS NOT NULL) OR (disposition = 'internal' AND company_id IS NULL)",
                         name: "work_hour_client_link_disposition_valid"
    end

    create_table :work_hour_staff_links do |t|
      t.references :organization, null: false, foreign_key: true, index: false
      t.bigint :tax_user_id, null: false
      t.string :email
      t.string :disposition, null: false
      t.references :employee, foreign_key: { on_delete: :cascade }
      t.boolean :active, null: false, default: true
      t.references :linked_by, foreign_key: { to_table: :users }
      t.timestamps
      t.index [ :organization_id, :tax_user_id ], unique: true
      t.check_constraint "(disposition = 'employee' AND employee_id IS NOT NULL) OR (disposition = 'no_payroll' AND employee_id IS NULL)",
                         name: "work_hour_staff_link_disposition_valid"
    end
  end
end
