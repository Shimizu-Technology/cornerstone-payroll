# frozen_string_literal: true

# Several files per portal message, typed "missing file" requests, and retry
# keys for composer uploads. Additive only: client_portal_messages keeps its
# client_document_id column (the first attachment) for older readers, and each
# existing single attachment is copied into the new join table.
class AddPortalMessageAttachmentsAndFileRequests < ActiveRecord::Migration[8.1]
  MESSAGE_KINDS = %w[message file_request file_response file_request_accepted file_request_asked_again file_request_withdrawn].freeze
  REQUEST_STATUSES = %w[requested responded accepted withdrawn].freeze

  def up
    add_index :client_portal_messages, [ :id, :company_id ], unique: true, name: "idx_client_portal_messages_tenant_key"

    create_table :portal_message_attachments do |t|
      t.references :company, null: false, foreign_key: true, index: false
      t.bigint :client_portal_message_id, null: false
      t.bigint :client_document_id, null: false
      t.integer :position, null: false, default: 0
      t.datetime :created_at, null: false
      t.index [ :client_portal_message_id, :client_document_id ], unique: true, name: "idx_portal_message_attachments_once"
      t.index :client_document_id, name: "idx_portal_message_attachments_document"
    end
    add_foreign_key :portal_message_attachments, :client_portal_messages, column: [ :client_portal_message_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_portal_message_attachments_message_tenant"
    add_foreign_key :portal_message_attachments, :client_documents, column: [ :client_document_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_portal_message_attachments_document_tenant"

    # Legacy messages were validated to the same company, so every link copies.
    execute <<~SQL.squish
      INSERT INTO portal_message_attachments (company_id, client_portal_message_id, client_document_id, position, created_at)
      SELECT m.company_id, m.id, m.client_document_id, 0, m.created_at
      FROM client_portal_messages m
      JOIN client_documents d ON d.id = m.client_document_id AND d.company_id = m.company_id
      WHERE m.client_document_id IS NOT NULL
      ON CONFLICT DO NOTHING
    SQL

    create_table :portal_file_requests do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :client_portal_thread_id, null: false
      t.references :requested_by, foreign_key: { to_table: :users }
      t.string :requested_by_name_snapshot
      t.string :title, null: false, limit: 200
      t.string :category, null: false
      t.bigint :employee_id
      t.bigint :payroll_submission_period_id
      t.date :due_on
      t.string :status, null: false, default: "requested"
      t.bigint :request_message_id
      t.bigint :last_response_message_id
      t.references :responded_by, foreign_key: { to_table: :users }
      t.datetime :responded_at
      t.references :resolved_by, foreign_key: { to_table: :users }
      t.datetime :resolved_at
      t.string :idempotency_key, limit: 128
      t.string :request_fingerprint, limit: 64
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :client_portal_thread_id, :status ], name: "idx_portal_file_requests_thread"
      t.index [ :payroll_submission_period_id, :status ], name: "idx_portal_file_requests_period",
        where: "payroll_submission_period_id IS NOT NULL"
      t.index [ :company_id, :status, :updated_at ], name: "idx_portal_file_requests_company_status"
      t.index [ :company_id, :requested_by_id, :idempotency_key ], unique: true,
        where: "idempotency_key IS NOT NULL", name: "idx_portal_file_requests_retry_key"
      t.index [ :id, :company_id ], unique: true, name: "idx_portal_file_requests_tenant_key"
      t.index :employee_id
      t.check_constraint "status IN (#{REQUEST_STATUSES.map { |s| "'#{s}'" }.join(', ')})", name: "portal_file_requests_status"
      t.check_constraint "(status IN ('accepted', 'withdrawn')) = (resolved_at IS NOT NULL)", name: "portal_file_requests_resolved_state"
    end
    add_foreign_key :portal_file_requests, :client_portal_threads, column: [ :client_portal_thread_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_portal_file_requests_thread_tenant"
    add_foreign_key :portal_file_requests, :employees, column: [ :employee_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_portal_file_requests_employee_tenant"
    add_foreign_key :portal_file_requests, :payroll_submission_periods, column: [ :payroll_submission_period_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_portal_file_requests_period_tenant"
    add_foreign_key :portal_file_requests, :client_portal_messages, column: [ :request_message_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_portal_file_requests_request_message_tenant"
    add_foreign_key :portal_file_requests, :client_portal_messages, column: [ :last_response_message_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_portal_file_requests_response_message_tenant"

    add_column :client_portal_messages, :kind, :string, null: false, default: "message"
    add_column :client_portal_messages, :portal_file_request_id, :bigint
    add_index :client_portal_messages, :portal_file_request_id, name: "idx_client_portal_messages_file_request",
      where: "portal_file_request_id IS NOT NULL"
    add_check_constraint :client_portal_messages, "kind IN (#{MESSAGE_KINDS.map { |k| "'#{k}'" }.join(', ')})", name: "portal_message_kind"
    add_check_constraint :client_portal_messages, "(kind = 'message') = (portal_file_request_id IS NULL)", name: "portal_message_kind_request"
    add_foreign_key :client_portal_messages, :portal_file_requests, column: [ :portal_file_request_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_client_portal_messages_file_request_tenant"

    # A retried composer upload returns the files saved the first time.
    add_column :client_documents, :upload_idempotency_key, :string, limit: 128
    add_column :client_documents, :upload_request_fingerprint, :string, limit: 64
    add_column :client_documents, :upload_position, :integer
    add_index :client_documents, [ :company_id, :uploaded_by_id, :upload_idempotency_key, :upload_position ], unique: true,
      where: "upload_idempotency_key IS NOT NULL", name: "idx_client_documents_upload_retry_key"
  end

  def down
    remove_index :client_documents, name: "idx_client_documents_upload_retry_key"
    remove_column :client_documents, :upload_position
    remove_column :client_documents, :upload_request_fingerprint
    remove_column :client_documents, :upload_idempotency_key

    remove_foreign_key :client_portal_messages, name: "fk_client_portal_messages_file_request_tenant"
    remove_check_constraint :client_portal_messages, name: "portal_message_kind_request"
    remove_check_constraint :client_portal_messages, name: "portal_message_kind"
    remove_index :client_portal_messages, name: "idx_client_portal_messages_file_request"
    remove_column :client_portal_messages, :portal_file_request_id
    remove_column :client_portal_messages, :kind

    drop_table :portal_file_requests
    drop_table :portal_message_attachments
    remove_index :client_portal_messages, name: "idx_client_portal_messages_tenant_key"
  end
end
