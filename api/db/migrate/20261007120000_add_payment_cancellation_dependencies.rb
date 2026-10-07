# frozen_string_literal: true

class AddPaymentCancellationDependencies < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :aire_payroll_entry_acknowledgements, name: "aire_payroll_entry_ack_status_check"
    add_check_constraint :aire_payroll_entry_acknowledgements,
      "status IN ('imported', 'committed', 'payment_prepared', 'payment_issued', 'payment_failed', 'payment_voided', 'payment_cancelled')",
      name: "aire_payroll_entry_ack_status_check"
    add_column :aire_payroll_entry_acknowledgements, :delivery_dependencies, :jsonb, null: false, default: []
    add_column :aire_payroll_entry_acknowledgements, :cancellation_metadata, :jsonb, null: false, default: {}
    add_check_constraint :aire_payroll_entry_acknowledgements, <<~SQL.squish, name: "aire_entry_payment_cancellation_shape"
      status <> 'payment_cancelled' OR (
        contract_version = '2.0' AND source_user_uuid IS NOT NULL AND
        payment_method IS NOT NULL AND payment_method = 'paper_check' AND payment_reference IS NOT NULL AND
        COALESCE(cancellation_metadata->>'cancelled_payment_event_id', '') <> '' AND
        COALESCE(cancellation_metadata->>'cancellation_evidence_reference', '') <> '' AND
        COALESCE(cancellation_metadata->'payroll_obligation_retained', 'false'::jsonb) = 'true'::jsonb
      )
    SQL
    add_column :time_tracking_manual_allocations, :payment_cancellation_intent, :jsonb, null: false, default: {}
    add_column :time_tracking_manual_allocations, :payment_cancellation_receipts, :jsonb, null: false, default: []
    add_column :time_tracking_manual_allocations, :payment_issue_intent, :jsonb, null: false, default: {}
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Payment cancellation evidence and stable command dependencies must be retained"
  end
end
