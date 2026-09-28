# frozen_string_literal: true

class TrackExpenseCreationPayment < ActiveRecord::Migration[7.1]
  def change
    add_column :expenses, :payment_included_at_creation, :boolean, default: false, null: false
  end
end
