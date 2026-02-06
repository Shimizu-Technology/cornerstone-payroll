class CreateTaxConfigAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :tax_config_audit_logs do |t|
      t.references :annual_tax_config, null: false, foreign_key: true
      t.bigint :user_id, null: true  # User ID (FK added when users table exists)
      t.string :action, null: false  # created, updated, activated, deactivated
      t.string :field_name, null: true  # which field changed (null for create)
      t.text :old_value, null: true
      t.text :new_value, null: true
      t.string :ip_address, null: true

      t.timestamp :created_at, null: false  # immutable - no updated_at
    end

    add_index :tax_config_audit_logs, :created_at
    add_index :tax_config_audit_logs, [ :annual_tax_config_id, :created_at ],
              name: 'idx_audit_logs_config_time'
  end
end
