# frozen_string_literal: true

class AddPaymentAttestationResolutionToManualAllocations < ActiveRecord::Migration[8.0]
  def change
    add_column :time_tracking_manual_allocations, :source_payment_attestation_id, :string
    add_column :time_tracking_manual_allocations, :payment_resolution_intent, :jsonb, null: false, default: {}
    add_column :time_tracking_manual_allocations, :payment_resolution_receipt, :jsonb, null: false, default: {}
    add_index :time_tracking_manual_allocations, [ :time_tracking_source_id, :source_payment_attestation_id ],
      unique: true, name: "index_manual_allocations_on_source_payment_attestation"
  end
end
