# frozen_string_literal: true

class AddClerkIdToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :clerk_id, :string
    add_index :users, :clerk_id, unique: true
  end
end
