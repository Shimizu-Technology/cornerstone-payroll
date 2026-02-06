class CreateUserInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :user_invitations do |t|
      t.references :company, null: false, foreign_key: true
      t.references :invited_by, null: false, foreign_key: { to_table: :users }
      t.string :email, null: false
      t.string :name
      t.integer :role, null: false, default: 2
      t.string :token, null: false
      t.datetime :invited_at, null: false
      t.datetime :accepted_at
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :user_invitations, :token, unique: true
    add_index :user_invitations, [ :company_id, :email, :accepted_at ], name: "idx_user_invitations_company_email"
  end
end
