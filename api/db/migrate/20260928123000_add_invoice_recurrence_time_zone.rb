# frozen_string_literal: true

class AddInvoiceRecurrenceTimeZone < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_recurrences, :time_zone, :string, default: "Pacific/Guam", null: false
  end
end
