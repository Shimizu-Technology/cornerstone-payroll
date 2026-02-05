# frozen_string_literal: true

class CreateDepartments < ActiveRecord::Migration[8.1]
  def change
    create_table :departments do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :departments, [ :company_id, :name ], unique: true
  end
end
