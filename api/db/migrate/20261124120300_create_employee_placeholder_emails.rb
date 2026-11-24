# frozen_string_literal: true

class CreateEmployeePlaceholderEmails < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_placeholder_emails do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :email, null: false
      t.string :reason
      t.references :marked_by, foreign_key: { to_table: :users, on_delete: :nullify }

      t.timestamps
    end

    add_index :employee_placeholder_emails, [ :organization_id, :email ],
              unique: true,
              name: "idx_employee_placeholder_emails_org_email"
  end
end
