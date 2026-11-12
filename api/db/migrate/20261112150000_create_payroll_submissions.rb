# frozen_string_literal: true

# Pay-period submissions from the client portal: numbered revisions of the
# client's payroll package, staff drafts for review, and the shared status
# history. Additive only; nothing here changes payroll or employee records.
class CreatePayrollSubmissions < ActiveRecord::Migration[8.1]
  STATUSES = %w[waiting_for_files submitted received in_review draft_ready approved changes_requested paid].freeze
  ROLES = %w[revel_payroll changes_workbook attachment].freeze

  def change
    add_index :client_portal_threads, [ :id, :company_id ], unique: true, name: "idx_client_portal_threads_tenant_key"

    create_table :payroll_submission_periods do |t|
      t.references :company, null: false, foreign_key: true
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.date :pay_date
      t.bigint :pay_period_id
      t.references :company_pay_schedule, foreign_key: true
      t.string :source, null: false
      t.string :status, null: false, default: "waiting_for_files"
      t.datetime :status_changed_at
      t.references :status_changed_by, foreign_key: { to_table: :users }
      t.bigint :client_portal_thread_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :company_id, :start_date, :end_date ], unique: true, name: "idx_payroll_submission_periods_dates"
      t.index [ :id, :company_id ], unique: true, name: "idx_payroll_submission_periods_tenant_key"
      t.index :pay_period_id, unique: true, where: "pay_period_id IS NOT NULL", name: "idx_payroll_submission_periods_pay_period"
      t.index :client_portal_thread_id, unique: true, where: "client_portal_thread_id IS NOT NULL", name: "idx_payroll_submission_periods_thread"
      t.check_constraint "end_date >= start_date", name: "payroll_submission_periods_dates_ordered"
      t.check_constraint "status IN (#{STATUSES.map { |s| "'#{s}'" }.join(', ')})", name: "payroll_submission_periods_status"
      t.check_constraint "source IN ('pay_period', 'schedule')", name: "payroll_submission_periods_source"
    end
    add_foreign_key :payroll_submission_periods, :pay_periods, column: [ :pay_period_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_payroll_submission_periods_pay_period_tenant"
    add_foreign_key :payroll_submission_periods, :client_portal_threads, column: [ :client_portal_thread_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_payroll_submission_periods_thread_tenant"

    create_table :payroll_submissions do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :payroll_submission_period_id, null: false
      t.integer :revision, null: false
      t.references :submitted_by, foreign_key: { to_table: :users }
      t.string :submitted_by_name_snapshot
      t.datetime :submitted_at, null: false
      t.boolean :no_changes, null: false, default: false
      t.jsonb :change_rows, null: false, default: []
      t.string :changes_link_url
      t.text :notes
      t.string :content_fingerprint, null: false
      t.string :request_fingerprint, null: false
      t.string :idempotency_key
      t.references :acknowledged_by, foreign_key: { to_table: :users }
      t.datetime :acknowledged_at
      t.timestamps
      t.index [ :payroll_submission_period_id, :revision ], unique: true, name: "idx_payroll_submissions_revision"
      t.index [ :payroll_submission_period_id, :submitted_by_id, :idempotency_key ], unique: true,
        where: "idempotency_key IS NOT NULL", name: "idx_payroll_submissions_retry_key"
      t.index [ :id, :company_id ], unique: true, name: "idx_payroll_submissions_tenant_key"
      t.check_constraint "revision > 0", name: "payroll_submissions_revision_positive"
      t.check_constraint "NOT no_changes OR change_rows = '[]'::jsonb", name: "payroll_submissions_no_changes_is_empty"
      t.check_constraint "jsonb_typeof(change_rows) = 'array'", name: "payroll_submissions_changes_array"
    end
    add_foreign_key :payroll_submissions, :payroll_submission_periods, column: [ :payroll_submission_period_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_payroll_submissions_period_tenant"

    create_table :payroll_submission_documents do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :payroll_submission_id, null: false
      t.bigint :client_document_id, null: false
      t.string :role, null: false
      t.integer :position, null: false, default: 0
      t.string :sha256, null: false, limit: 64
      t.string :file_name_snapshot, null: false
      t.bigint :file_size_snapshot, null: false
      t.timestamps
      t.index [ :payroll_submission_id, :client_document_id ], unique: true, name: "idx_payroll_submission_documents_once"
      t.index :payroll_submission_id, unique: true, where: "role = 'revel_payroll'", name: "idx_payroll_submission_documents_one_revel"
      t.index :payroll_submission_id, unique: true, where: "role = 'changes_workbook'", name: "idx_payroll_submission_documents_one_workbook"
      t.index :client_document_id
      t.check_constraint "role IN (#{ROLES.map { |r| "'#{r}'" }.join(', ')})", name: "payroll_submission_documents_role"
    end
    add_foreign_key :payroll_submission_documents, :payroll_submissions, column: [ :payroll_submission_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_payroll_submission_documents_submission_tenant"
    add_foreign_key :payroll_submission_documents, :client_documents, column: [ :client_document_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_payroll_submission_documents_document_tenant"

    create_table :payroll_submission_drafts do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :payroll_submission_period_id, null: false
      t.integer :revision, null: false
      t.bigint :paycheck_document_id
      t.bigint :direct_deposit_document_id
      t.text :note
      t.string :request_fingerprint, null: false
      t.references :created_by, foreign_key: { to_table: :users }
      t.datetime :posted_at
      t.references :posted_by, foreign_key: { to_table: :users }
      t.string :idempotency_key
      t.timestamps
      t.index [ :payroll_submission_period_id, :revision ], unique: true, name: "idx_payroll_submission_drafts_revision"
      t.index [ :payroll_submission_period_id, :created_by_id, :idempotency_key ], unique: true,
        where: "idempotency_key IS NOT NULL", name: "idx_payroll_submission_drafts_retry_key"
      t.index [ :id, :company_id ], unique: true, name: "idx_payroll_submission_drafts_tenant_key"
      t.index :paycheck_document_id
      t.index :direct_deposit_document_id
      t.check_constraint "paycheck_document_id IS NOT NULL OR direct_deposit_document_id IS NOT NULL",
        name: "payroll_submission_drafts_has_file"
      t.check_constraint "(posted_at IS NULL) = (posted_by_id IS NULL)", name: "payroll_submission_drafts_posted_actor"
    end
    add_foreign_key :payroll_submission_drafts, :payroll_submission_periods, column: [ :payroll_submission_period_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_payroll_submission_drafts_period_tenant"
    add_foreign_key :payroll_submission_drafts, :client_documents, column: [ :paycheck_document_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_payroll_submission_drafts_paycheck_tenant"
    add_foreign_key :payroll_submission_drafts, :client_documents, column: [ :direct_deposit_document_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_payroll_submission_drafts_direct_deposit_tenant"

    create_table :payroll_submission_status_events do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :payroll_submission_period_id, null: false
      t.string :event, null: false
      t.string :from_status, null: false
      t.string :to_status, null: false
      t.references :actor, foreign_key: { to_table: :users }
      t.string :actor_audience, null: false
      t.string :actor_name_snapshot
      t.bigint :payroll_submission_id
      t.bigint :payroll_submission_draft_id
      t.text :note
      t.datetime :created_at, null: false
      t.index [ :payroll_submission_period_id, :id ], name: "idx_payroll_submission_status_events_period"
      t.check_constraint "actor_audience IN ('client', 'staff')", name: "payroll_submission_status_events_audience"
    end
    add_foreign_key :payroll_submission_status_events, :payroll_submission_periods, column: [ :payroll_submission_period_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_payroll_submission_status_events_period_tenant"
    add_foreign_key :payroll_submission_status_events, :payroll_submissions, column: [ :payroll_submission_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_payroll_submission_status_events_submission_tenant"
    add_foreign_key :payroll_submission_status_events, :payroll_submission_drafts, column: [ :payroll_submission_draft_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_payroll_submission_status_events_draft_tenant"

    create_table :payroll_submission_period_read_receipts do |t|
      t.references :payroll_submission_period, null: false, foreign_key: true, index: false
      t.references :user, null: false, foreign_key: true
      t.bigint :last_seen_event_id, null: false, default: 0
      t.datetime :seen_at, null: false
      t.index [ :payroll_submission_period_id, :user_id ], unique: true, name: "idx_payroll_submission_period_reads_unique"
    end
  end
end
