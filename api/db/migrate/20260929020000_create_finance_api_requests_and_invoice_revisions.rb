# frozen_string_literal: true

class CreateFinanceApiRequestsAndInvoiceRevisions < ActiveRecord::Migration[8.1]
  def change
    add_column :invoices, :lock_version, :integer, default: 0, null: false

    create_table :finance_api_requests do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :finance_book, null: false, foreign_key: true
      t.references :finance_api_token, null: false, foreign_key: true
      t.references :invoice, foreign_key: true
      t.string :idempotency_key, null: false
      t.string :request_digest, null: false
      t.jsonb :response_payload, default: {}, null: false
      t.timestamps
    end

    add_index :finance_api_requests, [ :finance_book_id, :idempotency_key ], unique: true,
              name: "idx_finance_api_requests_book_key"
    add_index :finance_api_tokens, [ :id, :finance_book_id ], unique: true,
              name: "idx_finance_api_tokens_id_book"
    add_foreign_key :finance_api_requests, :finance_books,
                    column: [ :finance_book_id, :organization_id ], primary_key: [ :id, :organization_id ],
                    name: "fk_finance_api_requests_book_organization"
    add_foreign_key :finance_api_requests, :invoices,
                    column: [ :invoice_id, :finance_book_id ], primary_key: [ :id, :finance_book_id ],
                    name: "fk_finance_api_requests_invoice_book"
    add_foreign_key :finance_api_requests, :finance_api_tokens,
                    column: [ :finance_api_token_id, :finance_book_id ], primary_key: [ :id, :finance_book_id ],
                    name: "fk_finance_api_requests_token_book"
  end
end
