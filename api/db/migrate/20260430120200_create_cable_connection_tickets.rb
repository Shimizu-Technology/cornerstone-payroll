# frozen_string_literal: true

class CreateCableConnectionTickets < ActiveRecord::Migration[8.0]
  def change
    create_table :cable_connection_tickets do |t|
      t.references :user, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
    end

    add_index :cable_connection_tickets, :token_digest, unique: true
    add_index :cable_connection_tickets, [ :expires_at, :used_at ]
  end
end
