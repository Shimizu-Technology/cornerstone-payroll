# frozen_string_literal: true

class CreateInvoiceCenterAndAccountsReceivable < ActiveRecord::Migration[8.1]
  def up
    add_column :invoices, :due_date, :date
    add_column :invoices, :currency, :string, null: false, default: "USD"
    add_column :invoices, :customer_reference, :string
    add_column :invoices, :origin, :string, null: false, default: "native"
    add_column :invoices, :issued_at, :datetime
    add_column :invoices, :archived, :boolean, null: false, default: false
    add_column :invoices, :legacy_status, :string
    add_column :invoices, :source_metadata, :jsonb, null: false, default: {}

    add_index :invoices, [ :invoice_billing_profile_id, :status, :due_date ],
      name: "idx_invoices_on_profile_status_due_date"
    add_index :invoices, [ :organization_id, :archived, :invoice_date ],
      name: "idx_invoices_on_org_archive_invoice_date"
    add_check_constraint :invoices,
      "origin IN ('native', 'imported')",
      name: "check_invoices_origin"

    change_column_null :invoices, :company_id, true
    change_column_null :invoice_recipients, :company_id, true

    add_reference :invoice_chat_sessions, :organization, foreign_key: true
    execute <<~SQL.squish
      UPDATE invoice_chat_sessions
      SET organization_id = companies.organization_id
      FROM companies
      WHERE invoice_chat_sessions.company_id = companies.id
    SQL
    change_column_null :invoice_chat_sessions, :organization_id, false
    change_column_null :invoice_chat_sessions, :company_id, true
    add_index :invoice_chat_sessions, [ :organization_id, :archived, :updated_at ],
      name: "idx_invoice_chat_sessions_on_org_archive_updated"

    create_table :invoice_number_sequences do |t|
      t.references :invoice_billing_profile, null: false, foreign_key: true
      t.integer :sequence_year, null: false
      t.integer :last_number, null: false, default: 0
      t.timestamps
    end
    add_index :invoice_number_sequences,
      [ :invoice_billing_profile_id, :sequence_year ],
      unique: true,
      name: "idx_invoice_number_sequences_unique_year"
    add_check_constraint :invoice_number_sequences,
      "sequence_year >= 1900 AND sequence_year <= 9999",
      name: "check_invoice_number_sequence_year"
    add_check_constraint :invoice_number_sequences,
      "last_number >= 0",
      name: "check_invoice_number_sequence_last_number"

    create_table :invoice_artifacts do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :storage_key, null: false
      t.string :filename, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.string :sha256, null: false
      t.string :renderer_version
      t.string :template_version
      t.references :created_by, foreign_key: { to_table: :users }
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :invoice_artifacts, :storage_key, unique: true
    add_index :invoice_artifacts, [ :invoice_id, :kind, :created_at ],
      name: "idx_invoice_artifacts_on_invoice_kind_created"
    add_check_constraint :invoice_artifacts,
      "kind IN ('issued_pdf', 'imported_original', 'legacy_snapshot', 'credit_note', 'payment_receipt')",
      name: "check_invoice_artifacts_kind"
    add_check_constraint :invoice_artifacts, "byte_size >= 0", name: "check_invoice_artifacts_byte_size"

    create_table :invoice_events do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false
      t.references :actor, foreign_key: { to_table: :users }
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :invoice_events, [ :invoice_id, :occurred_at, :id ],
      name: "idx_invoice_events_timeline"

    create_table :invoice_payments do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.decimal :amount, precision: 14, scale: 2, null: false
      t.date :received_on, null: false
      t.string :payment_method, null: false
      t.string :reference_number
      t.text :notes
      t.string :currency, null: false, default: "USD"
      t.references :recorded_by, foreign_key: { to_table: :users }
      t.datetime :reversed_at
      t.references :reversed_by, foreign_key: { to_table: :users }
      t.text :reversal_reason
      t.boolean :system_generated, null: false, default: false
      t.timestamps
    end
    add_index :invoice_payments, [ :invoice_id, :received_on ], name: "idx_invoice_payments_on_invoice_received"
    add_check_constraint :invoice_payments, "amount > 0", name: "check_invoice_payments_positive_amount"
    add_check_constraint :invoice_payments,
      "payment_method IN ('cash', 'check', 'ach', 'card', 'wire', 'adjustment', 'legacy', 'other')",
      name: "check_invoice_payments_method"
    add_check_constraint :invoice_payments,
      "(reversed_at IS NULL AND reversed_by_id IS NULL AND reversal_reason IS NULL) OR " \
      "(reversed_at IS NOT NULL AND reversal_reason IS NOT NULL)",
      name: "check_invoice_payments_reversal_fields"

    create_table :invoice_credit_notes do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.string :credit_number, null: false
      t.date :issue_date, null: false
      t.text :reason, null: false
      t.decimal :total_amount, precision: 14, scale: 2, null: false
      t.string :currency, null: false, default: "USD"
      t.string :status, null: false, default: "issued"
      t.references :issued_by, foreign_key: { to_table: :users }
      t.datetime :voided_at
      t.references :voided_by, foreign_key: { to_table: :users }
      t.text :void_reason
      t.timestamps
    end
    add_index :invoice_credit_notes, [ :organization_id, :credit_number ], unique: true,
      name: "idx_invoice_credit_notes_unique_number"
    add_index :invoice_credit_notes, [ :invoice_id, :issue_date ], name: "idx_invoice_credit_notes_invoice_date"
    add_check_constraint :invoice_credit_notes, "total_amount > 0", name: "check_invoice_credit_notes_positive_amount"
    add_check_constraint :invoice_credit_notes,
      "status IN ('issued', 'voided')",
      name: "check_invoice_credit_notes_status"

    create_table :invoice_deliveries do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.references :invoice_artifact, foreign_key: true
      t.string :channel, null: false
      t.string :recipient
      t.datetime :delivered_at, null: false
      t.string :provider_reference
      t.text :notes
      t.references :recorded_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :invoice_deliveries, [ :invoice_id, :delivered_at ], name: "idx_invoice_deliveries_invoice_date"
    add_check_constraint :invoice_deliveries,
      "channel IN ('email', 'mail', 'hand_delivery', 'portal', 'other')",
      name: "check_invoice_deliveries_channel"

    migrate_legacy_invoice_state
    replace_invoice_status_constraint
    seed_invoice_number_sequences
    seed_legacy_events_and_payments
  end

  def down
    restore_legacy_invoice_state

    drop_table :invoice_deliveries
    drop_table :invoice_credit_notes
    drop_table :invoice_payments
    drop_table :invoice_events
    drop_table :invoice_artifacts
    drop_table :invoice_number_sequences

    remove_index :invoice_chat_sessions, name: "idx_invoice_chat_sessions_on_org_archive_updated"
    execute <<~SQL.squish
      UPDATE invoice_chat_sessions
      SET company_id = COALESCE(
        invoice_chat_sessions.company_id,
        organizations.primary_company_id,
        (SELECT companies.id FROM companies WHERE companies.organization_id = invoice_chat_sessions.organization_id ORDER BY companies.id LIMIT 1)
      )
      FROM organizations
      WHERE organizations.id = invoice_chat_sessions.organization_id
    SQL
    change_column_null :invoice_chat_sessions, :company_id, false
    remove_reference :invoice_chat_sessions, :organization, foreign_key: true

    execute <<~SQL.squish
      UPDATE invoices
      SET company_id = COALESCE(
        invoices.company_id,
        organizations.primary_company_id,
        (SELECT companies.id FROM companies WHERE companies.organization_id = invoices.organization_id ORDER BY companies.id LIMIT 1)
      )
      FROM organizations
      WHERE organizations.id = invoices.organization_id
    SQL
    execute <<~SQL.squish
      UPDATE invoice_recipients
      SET company_id = COALESCE(
        invoice_recipients.company_id,
        organizations.primary_company_id,
        (SELECT companies.id FROM companies WHERE companies.organization_id = invoice_recipients.organization_id ORDER BY companies.id LIMIT 1)
      )
      FROM organizations
      WHERE organizations.id = invoice_recipients.organization_id
    SQL
    change_column_null :invoices, :company_id, false
    change_column_null :invoice_recipients, :company_id, false

    remove_check_constraint :invoices, name: "check_invoices_origin"
    remove_index :invoices, name: "idx_invoices_on_org_archive_invoice_date"
    remove_index :invoices, name: "idx_invoices_on_profile_status_due_date"
    remove_column :invoices, :source_metadata
    remove_column :invoices, :legacy_status
    remove_column :invoices, :archived
    remove_column :invoices, :issued_at
    remove_column :invoices, :origin
    remove_column :invoices, :customer_reference
    remove_column :invoices, :currency
    remove_column :invoices, :due_date
  end

  private

  def migrate_legacy_invoice_state
    execute "UPDATE invoices SET legacy_status = status"
    remove_check_constraint :invoices, name: "check_invoices_status"

    execute <<~SQL.squish
      UPDATE invoices
      SET
        archived = (status = 'archived'),
        issued_at = CASE
          WHEN status IN ('generated', 'sent', 'paid', 'voided', 'archived')
            THEN COALESCE(generated_at, sent_at, paid_at, voided_at, created_at)
          ELSE NULL
        END,
        status = CASE
          WHEN status = 'voided' OR (status = 'archived' AND voided_at IS NOT NULL) THEN 'voided'
          WHEN status = 'draft' OR (status = 'archived' AND generated_at IS NULL AND sent_at IS NULL AND paid_at IS NULL) THEN 'draft'
          ELSE 'open'
        END
    SQL
  end

  def replace_invoice_status_constraint
    add_check_constraint :invoices,
      "status IN ('draft', 'open', 'voided', 'uncollectible')",
      name: "check_invoices_status"
  end

  def seed_invoice_number_sequences
    execute <<~SQL.squish
      INSERT INTO invoice_number_sequences (
        invoice_billing_profile_id, sequence_year, last_number, created_at, updated_at
      )
      SELECT
        invoice_billing_profile_id,
        EXTRACT(YEAR FROM invoice_date)::integer,
        COUNT(*)::integer,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      FROM invoices
      GROUP BY invoice_billing_profile_id, EXTRACT(YEAR FROM invoice_date)::integer
      ON CONFLICT (invoice_billing_profile_id, sequence_year) DO NOTHING
    SQL
  end

  def seed_legacy_events_and_payments
    execute <<~SQL.squish
      INSERT INTO invoice_events (
        organization_id, invoice_id, event_type, occurred_at, metadata, created_at, updated_at
      )
      SELECT organization_id, id, 'legacy_imported', created_at,
        jsonb_build_object('legacy_status', legacy_status), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM invoices
    SQL

    execute <<~SQL.squish
      INSERT INTO invoice_events (
        organization_id, invoice_id, event_type, occurred_at, metadata, created_at, updated_at
      )
      SELECT organization_id, id, 'issued', issued_at,
        jsonb_build_object('source', 'legacy_migration'), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM invoices
      WHERE issued_at IS NOT NULL
    SQL

    execute <<~SQL.squish
      INSERT INTO invoice_deliveries (
        organization_id, invoice_id, channel, recipient, delivered_at, notes, created_at, updated_at
      )
      SELECT invoices.organization_id, invoices.id, 'email', invoice_recipients.email,
        invoices.sent_at, 'Preserved from legacy sent timestamp', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM invoices
      JOIN invoice_recipients ON invoice_recipients.id = invoices.invoice_recipient_id
      WHERE invoices.sent_at IS NOT NULL
    SQL

    execute <<~SQL.squish
      INSERT INTO invoice_payments (
        organization_id, invoice_id, amount, received_on, payment_method, notes, currency,
        system_generated, created_at, updated_at
      )
      SELECT organization_id, id, total_amount, COALESCE(paid_at::date, invoice_date), 'legacy',
        'Preserved from legacy paid status', currency, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM invoices
      WHERE paid_at IS NOT NULL AND total_amount > 0
    SQL

    execute <<~SQL.squish
      INSERT INTO invoice_events (
        organization_id, invoice_id, event_type, occurred_at, metadata, created_at, updated_at
      )
      SELECT organization_id, id, 'archived', COALESCE(archived_at, updated_at),
        jsonb_build_object('source', 'legacy_migration'), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM invoices
      WHERE archived = TRUE
    SQL
  end

  def restore_legacy_invoice_state
    remove_check_constraint :invoices, name: "check_invoices_status"
    execute <<~SQL.squish
      UPDATE invoices
      SET status = COALESCE(legacy_status,
        CASE
          WHEN archived THEN 'archived'
          WHEN status = 'open' THEN 'generated'
          ELSE status
        END)
    SQL
    add_check_constraint :invoices,
      "status IN ('draft', 'generated', 'sent', 'paid', 'voided', 'archived')",
      name: "check_invoices_status"
  end
end
