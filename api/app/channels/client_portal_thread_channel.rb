# frozen_string_literal: true

class ClientPortalThreadChannel < ApplicationCable::Channel
  def subscribed
    return reject unless current_user&.payroll_access_allowed?
    return reject unless current_user.can_access_company?(current_company.id)

    stream_for current_company, coder: ActiveSupport::JSON do |message|
      transmit_if_authorized(message)
    end
  end

  def self.broadcast_thread(thread, event:)
    serializer = ClientPortalThreadSerializer.new(current_user: nil)
    payload = serializer.thread(thread, include_messages: true)
    payload.delete(:unread)

    broadcast_to(
      thread.company,
      {
        event: event,
        thread: payload
      }
    )
  end

  private

  # Revocation jobs normally close existing sockets immediately. Rechecking at
  # the final delivery boundary prevents a stale socket from receiving payroll
  # data even if both the queue and Cable adapter are temporarily unavailable.
  def transmit_if_authorized(message)
    current_user.reload
    if current_user.payroll_access_allowed? && current_user.can_access_company?(current_company.id)
      transmit(message)
    else
      revoke_subscription
    end
  rescue ActiveRecord::RecordNotFound
    revoke_subscription
  end

  def revoke_subscription
    stop_all_streams
    connection.close(reason: "Payroll access revoked", reconnect: false)
  end
end
