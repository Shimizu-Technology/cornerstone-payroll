# frozen_string_literal: true

# Audit log for non-employee check edits. Every time a user updates an editable
# field (payable_to, amount, memo, etc.), we record a row capturing the
# before/after snapshot, who did it, and an optional reason. This gives us a
# permanent paper trail that survives further edits and voids.
class CreateNonEmployeeCheckEdits < ActiveRecord::Migration[8.0]
  def change
    create_table :non_employee_check_edits do |t|
      t.references :non_employee_check, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.references :edited_by, foreign_key: { to_table: :users }, null: true
      t.jsonb :before, null: false, default: {}
      t.jsonb :after, null: false, default: {}
      t.jsonb :changed_fields, null: false, default: []
      t.string :reason
      t.datetime :created_at, null: false
    end

    add_index :non_employee_check_edits, :created_at
  end
end
