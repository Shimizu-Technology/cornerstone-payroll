# frozen_string_literal: true

class InvoiceSendJob < ApplicationJob
  self.rls_mode = :exempt_tables_only

  queue_as :default

  def perform(schedule_id)
    InvoiceScheduledSender.send!(schedule_id)
  end
end
