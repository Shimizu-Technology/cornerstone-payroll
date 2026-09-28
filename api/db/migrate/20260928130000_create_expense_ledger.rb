# frozen_string_literal: true

class CreateExpenseLedger < ActiveRecord::Migration[8.0]
  def change
    create_table :expense_vendors do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.string :email
      t.text :notes
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :expense_vendors, [ :organization_id, :name ], unique: true

    create_table :expenses do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :expense_vendor, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :updated_by, foreign_key: { to_table: :users }
      t.string :reference_number
      t.string :source_key
      t.string :category, null: false
      t.text :description, null: false
      t.date :expense_on, null: false
      t.date :due_on
      t.decimal :total_amount, precision: 12, scale: 2, null: false
      t.string :currency, null: false, default: "USD"
      t.datetime :voided_at
      t.text :void_reason
      t.timestamps
    end
    add_index :expenses, [ :organization_id, :source_key ], unique: true, where: "source_key IS NOT NULL"
    add_index :expenses, [ :organization_id, :expense_on ]
    add_index :expenses, [ :organization_id, :due_on ]
    add_check_constraint :expenses, "total_amount > 0", name: "check_expense_total_positive"
    add_check_constraint :expenses, "currency ~ '^[A-Z]{3}$'", name: "check_expense_currency"

    create_table :expense_payments do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :expense, null: false, foreign_key: true
      t.references :recorded_by, foreign_key: { to_table: :users }
      t.references :reversed_by, foreign_key: { to_table: :users }
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.date :paid_on, null: false
      t.string :payment_method, null: false
      t.string :reference_number
      t.text :notes
      t.datetime :reversed_at
      t.text :reversal_reason
      t.timestamps
    end
    add_index :expense_payments, [ :expense_id, :reversed_at ]
    add_check_constraint :expense_payments, "amount > 0", name: "check_expense_payment_positive"

    create_table :expense_artifacts do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :expense, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.string :storage_key, null: false
      t.string :filename, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.string :sha256, null: false
      t.timestamps
    end
    add_index :expense_artifacts, :storage_key, unique: true
  end
end
