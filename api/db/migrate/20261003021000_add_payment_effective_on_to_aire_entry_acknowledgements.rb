# frozen_string_literal: true

class AddPaymentEffectiveOnToAireEntryAcknowledgements < ActiveRecord::Migration[8.1]
  def change
    add_column :aire_payroll_entry_acknowledgements, :payment_effective_on, :date
  end
end
