# frozen_string_literal: true

# What an emailed invoice actually said. The invoice's email text can change
# after issue, so each provider delivery keeps the subject and body it sent.
class AddEmailContentToInvoiceDeliveries < ActiveRecord::Migration[8.1]
  def change
    add_column :invoice_deliveries, :email_subject, :text
    add_column :invoice_deliveries, :email_body, :text
  end
end
