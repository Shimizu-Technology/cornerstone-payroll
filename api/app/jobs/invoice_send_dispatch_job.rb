# frozen_string_literal: true

class InvoiceSendDispatchJob < ApplicationJob
  queue_as :default

  def perform
    # A worker can exit after claiming an email. Leave it for explicit review and
    # retry rather than automatically sending a second copy after a timeout.
    InvoiceSendSchedule.where(status: "sending").where("claimed_at < ?", 1.hour.ago)
                       .update_all(status: "failed", last_error: "Sending was interrupted; verify provider delivery before retrying", updated_at: Time.current)

    InvoiceSendSchedule.due.order(:send_at, :id).limit(100).pluck(:id).each do |id|
      InvoiceSendJob.perform_later(id)
    end
  end
end
