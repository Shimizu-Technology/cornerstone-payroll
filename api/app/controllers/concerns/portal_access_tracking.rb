# frozen_string_literal: true

module PortalAccessTracking
  extend ActiveSupport::Concern

  included do
    prepend_around_action :track_portal_failure
  end

  private

  def track_portal_failure
    yield
    record_portal_failure(response.status, response.status == 403 ? "access_denied" : "request_failed") unless response.successful?
  rescue StandardError
    record_portal_failure(500, "internal_error")
    raise
  ensure
    Current.reset
  end

  def record_portal_failure(status, reason)
    # Never resolve the requested resource or copy request params/error messages.
    AuditLog.record!(user: current_user, company_id: nil, action: "portal_access#failed",
      record_type: "portal_access", event_category: "security",
      metadata: { status: status, reason: reason, operation: action_name })
  rescue StandardError => error
    Rails.logger.error("Portal failure audit unavailable: #{error.class.name}")
  end

  def portal_activity_response(resource)
    logs = bounded_page(PortalActivity.feed(resource))
    render json: { data: logs.map { |log| PortalActivity.serialize(log) }, meta: bounded_page_meta(logs) }
  end
end
