# frozen_string_literal: true

class EnforceFinanceBookRelationships < ActiveRecord::Migration[8.1]
  PARENTS = %i[companies invoice_billing_profiles invoice_recipients invoices expense_vendors].freeze
  RELATIONSHIPS = [
    [ :finance_books, :companies, :company_id, :organization_id ],
    [ :invoices, :invoice_billing_profiles, :invoice_billing_profile_id, :finance_book_id ],
    [ :invoices, :invoice_recipients, :invoice_recipient_id, :finance_book_id ],
    [ :invoice_chat_sessions, :invoices, :invoice_id, :finance_book_id ],
    [ :invoice_chat_sessions, :invoice_recipients, :invoice_recipient_id, :finance_book_id ],
    [ :invoice_recurrences, :invoices, :source_invoice_id, :finance_book_id ],
    [ :invoice_send_schedules, :invoices, :invoice_id, :finance_book_id ],
    [ :expenses, :expense_vendors, :expense_vendor_id, :finance_book_id ]
  ].freeze

  def up
    PARENTS.each do |table|
      scope = table == :companies ? :organization_id : :finance_book_id
      add_index table, [ :id, scope ], unique: true, name: "index_#{table}_on_id_and_#{scope}"
    end
    RELATIONSHIPS.each do |child, parent, foreign_id, scope|
      add_foreign_key child, parent, column: [ foreign_id, scope ], primary_key: [ :id, scope ],
                      deferrable: :deferred, name: "fk_#{child}_#{foreign_id}_book_scope"
    end
  end

  def down
    RELATIONSHIPS.reverse_each do |child, _parent, foreign_id, _scope|
      remove_foreign_key child, name: "fk_#{child}_#{foreign_id}_book_scope"
    end
    PARENTS.reverse_each do |table|
      scope = table == :companies ? :organization_id : :finance_book_id
      remove_index table, name: "index_#{table}_on_id_and_#{scope}"
    end
  end
end
