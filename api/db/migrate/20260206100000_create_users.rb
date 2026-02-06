class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.references :company, null: false, foreign_key: true
      t.string :email, null: false
      t.string :name, null: false
      t.integer :role, null: false, default: 0
      t.string :workos_id
      t.boolean :active, null: false, default: true
      t.datetime :last_login_at

      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, :workos_id, unique: true
  end
end
