# frozen_string_literal: true

class PortalDisplayReceipt
  def self.issue(thread:, user:, messages:)
    Rails.application.message_verifier("portal_display").generate(
      { thread_id: thread.id, user_id: user.id, message_ids: messages.map(&:id) }, expires_in: 30.minutes)
  end

  def self.verify(token:, thread:, user:, ids:)
    payload = Rails.application.message_verifier("portal_display").verified(token)
    payload = payload&.with_indifferent_access
    payload && payload[:thread_id] == thread.id && payload[:user_id] == user.id &&
      ids.present? && (ids - payload[:message_ids]).empty?
  end
end
