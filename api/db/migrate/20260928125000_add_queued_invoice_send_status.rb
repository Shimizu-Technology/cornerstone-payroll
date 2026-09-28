# frozen_string_literal: true

class AddQueuedInvoiceSendStatus < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :invoice_send_schedules, name: "check_invoice_send_schedule_status"
    add_check_constraint :invoice_send_schedules,
                         "status IN ('pending', 'queued', 'sending', 'sent', 'failed', 'cancelled')",
                         name: "check_invoice_send_schedule_status"
  end

  def down
    execute "UPDATE invoice_send_schedules SET status = 'pending' WHERE status = 'queued'"
    remove_check_constraint :invoice_send_schedules, name: "check_invoice_send_schedule_status"
    add_check_constraint :invoice_send_schedules,
                         "status IN ('pending', 'sending', 'sent', 'failed', 'cancelled')",
                         name: "check_invoice_send_schedule_status"
  end
end
