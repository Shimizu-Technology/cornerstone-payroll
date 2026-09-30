# frozen_string_literal: true

class AddPayableLineIdentityToAirePayrollEntryAcknowledgements < ActiveRecord::Migration[8.1]
  def change
    change_table :aire_payroll_entry_acknowledgements, bulk: true do |t|
      t.string :contract_version
      t.string :source_line_key
      t.string :source_kind
      t.decimal :total_hours, precision: 8, scale: 2
      t.decimal :regular_hours, precision: 8, scale: 2
      t.decimal :overtime_hours, precision: 8, scale: 2
    end

    add_index :aire_payroll_entry_acknowledgements,
              [ :time_tracking_import_id, :source_time_entry_id, :source_line_key, :status ],
              name: "idx_aire_entry_ack_payable_line_status"
    add_check_constraint :aire_payroll_entry_acknowledgements, <<~SQL.squish, name: "aire_entry_ack_line_contract_shape"
      (contract_version IS NULL AND source_line_key IS NULL AND source_kind IS NULL AND total_hours IS NULL AND regular_hours IS NULL AND overtime_hours IS NULL)
      OR
      (contract_version = '2.0' AND source_line_key IS NOT NULL AND source_kind IN ('current', 'carryover', 'correction') AND total_hours IS NOT NULL AND regular_hours IS NOT NULL AND overtime_hours IS NOT NULL AND total_hours = regular_hours + overtime_hours)
    SQL
  end
end
