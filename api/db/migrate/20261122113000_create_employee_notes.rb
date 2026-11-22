# frozen_string_literal: true

class CreateEmployeeNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_notes do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :employee, null: false, foreign_key: true, index: true
      t.text :body, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }, index: true
      t.datetime :hidden_at
      t.references :hidden_by, null: true, foreign_key: { to_table: :users }, index: true
      t.text :hidden_reason

      t.timestamps
    end

    add_index :employee_notes,
              [ :company_id, :employee_id, :created_at, :id ],
              name: "index_employee_notes_on_company_employee_created"
  end
end
