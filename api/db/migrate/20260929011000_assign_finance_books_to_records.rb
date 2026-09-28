# frozen_string_literal: true

class AssignFinanceBooksToRecords < ActiveRecord::Migration[8.1]
  TABLES = %i[
    invoice_billing_profiles invoice_recipients invoices invoice_chat_sessions
    invoice_recurrences invoice_send_schedules expense_vendors expenses
  ].freeze

  def up
    TABLES.each do |table|
      add_reference table, :finance_book, foreign_key: true, null: true
      execute <<~SQL.squish
        UPDATE #{table} AS record
        SET finance_book_id = book.id
        FROM finance_books AS book
        WHERE book.organization_id = record.organization_id AND book.is_default = true
      SQL
      change_column_null table, :finance_book_id, false
    end
  end

  def down
    TABLES.reverse_each { |table| remove_reference table, :finance_book, foreign_key: true }
  end
end
