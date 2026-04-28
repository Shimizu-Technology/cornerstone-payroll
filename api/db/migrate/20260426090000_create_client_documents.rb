# frozen_string_literal: true

class CreateClientDocuments < ActiveRecord::Migration[8.0]
  def change
    create_table :client_documents do |t|
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: true, foreign_key: true
      t.references :uploaded_by, null: false, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.string :category, null: false
      t.string :file_name, null: false
      t.string :file_key, null: false
      t.string :content_type, null: false
      t.bigint :file_size, null: false, default: 0
      t.text :notes
      t.timestamps
    end

    add_index :client_documents, :file_key, unique: true
    add_index :client_documents, [:company_id, :category]
    add_index :client_documents, [:company_id, :created_at]
  end
end
