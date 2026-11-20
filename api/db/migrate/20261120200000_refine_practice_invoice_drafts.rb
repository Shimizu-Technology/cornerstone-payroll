# frozen_string_literal: true

class RefinePracticeInvoiceDrafts < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_line_items, :item_name, :string, null: false, default: ""
    add_column :invoice_line_items, :description_template, :text
    add_column :invoice_line_items, :reimbursement_review_required, :boolean, null: false, default: false
    add_column :invoices, :due_date_manual, :boolean, null: false, default: false
    add_column :invoices, :service_period_manual, :boolean, null: false, default: false
    reversible do |dir|
      dir.up do
        execute "UPDATE invoices SET service_period_manual = true WHERE service_period_start IS NOT NULL OR service_period_end IS NOT NULL"
        execute <<~SQL
          UPDATE invoices SET due_date_manual = true
          WHERE due_date IS NOT NULL AND NOT COALESCE((
            (payment_terms ~* '^Net [0-9]+$' AND due_date = invoice_date + substring(payment_terms from '[0-9]+')::integer)
            OR (lower(payment_terms) = 'due on receipt' AND due_date = invoice_date)
          ), false)
        SQL
      end
    end
  end
end
