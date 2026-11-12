# frozen_string_literal: true

module PortalInboxUpdates
  extend ActiveSupport::Concern

  included do
    after_commit :invalidate_portal_inbox
  end

  private

  def invalidate_portal_inbox
    ClientInboxChannel.broadcast_to(company.organization, event: "work_changed")
  rescue StandardError => error
    # A lost invalidation must not turn a committed write into a failed request.
    # Focus/reconnect and the visibility-aware fallback refresh the same query.
    Rails.logger.warn("Portal inbox invalidation unavailable: #{error.class.name}")
  end
end
