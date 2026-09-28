# frozen_string_literal: true

class CreateFinanceApiTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :finance_api_tokens do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :finance_book, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :scopes, array: true, default: [ "read" ], null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.timestamps
    end

    add_index :finance_api_tokens, :token_digest, unique: true
    add_index :finance_api_tokens, [ :finance_book_id, :revoked_at ]
    add_foreign_key :finance_api_tokens, :finance_books,
                    column: [ :finance_book_id, :organization_id ], primary_key: [ :id, :organization_id ],
                    name: "fk_finance_api_tokens_book_organization"
  end
end
