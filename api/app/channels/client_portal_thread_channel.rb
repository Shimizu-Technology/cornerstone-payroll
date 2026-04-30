# frozen_string_literal: true

class ClientPortalThreadChannel < ApplicationCable::Channel
  def subscribed
    return reject unless current_user&.can_access_company?(current_company.id)

    stream_for current_company
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
end
