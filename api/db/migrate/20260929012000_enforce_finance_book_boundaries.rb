# frozen_string_literal: true

class EnforceFinanceBookBoundaries < ActiveRecord::Migration[8.1]
  TABLES = %i[
    invoice_billing_profiles invoice_recipients invoices invoice_chat_sessions
    invoice_recurrences invoice_send_schedules expense_vendors expenses
  ].freeze

  def up
    add_index :finance_books, [ :id, :organization_id ], unique: true,
              name: "index_finance_books_on_id_and_organization_id"
    TABLES.each do |table|
      add_foreign_key table, :finance_books,
                      column: [ :finance_book_id, :organization_id ],
                      primary_key: [ :id, :organization_id ],
                      name: "fk_#{table}_book_organization"
    end

    remove_index :expense_vendors, name: "index_expense_vendors_on_organization_id_and_name"
    add_index :expense_vendors, [ :finance_book_id, :name ], unique: true
    remove_index :expenses, name: "index_expenses_on_organization_id_and_source_key"
    add_index :expenses, [ :finance_book_id, :source_key ], unique: true,
              where: "source_key IS NOT NULL", name: "index_expenses_on_book_and_source_key"
    remove_index :invoice_billing_profiles, name: "index_invoice_billing_profiles_one_default_per_org"
    add_index :invoice_billing_profiles, [ :finance_book_id, :is_default ], unique: true,
              where: "is_default = true", name: "index_invoice_billing_profiles_one_default_per_book"
    remove_index :invoice_billing_profiles, name: "index_invoice_billing_profiles_on_organization_id_and_name"
    add_index :invoice_billing_profiles, [ :finance_book_id, :name ], unique: true
  end

  def down
    remove_index :invoice_billing_profiles, column: [ :finance_book_id, :name ]
    add_index :invoice_billing_profiles, [ :organization_id, :name ], unique: true
    remove_index :invoice_billing_profiles, name: "index_invoice_billing_profiles_one_default_per_book"
    add_index :invoice_billing_profiles, [ :organization_id, :is_default ], unique: true,
              where: "is_default = true", name: "index_invoice_billing_profiles_one_default_per_org"
    remove_index :expenses, name: "index_expenses_on_book_and_source_key"
    add_index :expenses, [ :organization_id, :source_key ], unique: true,
              where: "source_key IS NOT NULL"
    remove_index :expense_vendors, column: [ :finance_book_id, :name ]
    add_index :expense_vendors, [ :organization_id, :name ], unique: true

    TABLES.reverse_each { |table| remove_foreign_key table, name: "fk_#{table}_book_organization" }
    remove_index :finance_books, name: "index_finance_books_on_id_and_organization_id"
  end
end
