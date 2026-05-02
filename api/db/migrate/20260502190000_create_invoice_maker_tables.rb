# frozen_string_literal: true

class CreateInvoiceMakerTables < ActiveRecord::Migration[8.1]
  def change
    create_table :invoice_recipients do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.string :email
      t.text :address
      t.decimal :default_rate, precision: 12, scale: 2
      t.string :invoice_prefix
      t.text :payment_terms
      t.string :template_type, null: false, default: "standard"
      t.text :notes
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :invoice_recipients, [ :company_id, :name ]

    create_table :invoices do |t|
      t.references :company, null: false, foreign_key: true
      t.references :invoice_recipient, null: false, foreign_key: true
      t.string :invoice_number, null: false
      t.date :invoice_date, null: false
      t.date :service_period_start
      t.date :service_period_end
      t.decimal :total_amount, precision: 12, scale: 2, null: false, default: 0
      t.string :status, null: false, default: "draft"
      t.text :notes
      t.text :payment_terms
      t.string :email_subject
      t.text :email_body
      t.datetime :generated_at
      t.datetime :sent_at
      t.datetime :paid_at
      t.datetime :voided_at
      t.datetime :archived_at
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :updated_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :invoices, [ :company_id, :invoice_number ], unique: true
    add_index :invoices, [ :company_id, :status ]
    add_index :invoices, [ :company_id, :invoice_date ]
    add_check_constraint :invoices,
      "status IN ('draft', 'generated', 'sent', 'paid', 'voided', 'archived')",
      name: "check_invoices_status"

    create_table :invoice_line_items do |t|
      t.references :invoice, null: false, foreign_key: true
      t.text :description, null: false
      t.decimal :quantity, precision: 12, scale: 2, null: false, default: 1
      t.decimal :rate, precision: 12, scale: 2, null: false, default: 0
      t.decimal :amount, precision: 12, scale: 2, null: false, default: 0
      t.date :service_date
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :invoice_line_items, [ :invoice_id, :position ]
  end
end
