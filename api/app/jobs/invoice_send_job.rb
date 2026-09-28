# frozen_string_literal: true

class InvoiceSendJob < ApplicationJob
  queue_as :default

  def perform(schedule_id)
    InvoiceScheduledSender.send!(schedule_id)
  end
end
