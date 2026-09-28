# frozen_string_literal: true

class FreezeInvoiceEmailPayloads < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_send_schedules, :rendered_subject, :text
    add_column :invoice_send_schedules, :rendered_body, :text
    add_column :invoice_send_schedules, :sender_email, :string
    add_column :invoice_send_schedules, :reply_to_email, :string
    add_column :invoice_send_schedules, :first_claimed_at, :datetime
  end
end
