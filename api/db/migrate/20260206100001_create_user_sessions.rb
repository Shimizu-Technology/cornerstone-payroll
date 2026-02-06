class CreateUserSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :user_sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :jti, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.text :workos_access_token
      t.string :ip_address
      t.string :user_agent

      t.timestamps
    end

    add_index :user_sessions, :jti, unique: true
    add_index :user_sessions, :expires_at
  end
end
