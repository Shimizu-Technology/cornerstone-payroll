# frozen_string_literal: true

class PreventDuplicateActiveInvoiceRecurrences < ActiveRecord::Migration[8.0]
  def change
    add_index :invoice_recurrences, :source_invoice_id, unique: true, where: "active = true",
              name: "index_active_invoice_recurrences_on_source"
  end
end
