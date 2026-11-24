# frozen_string_literal: true

require "digest"

module EmployeeContactLoginRejectionGuard
  extend ActiveSupport::Concern

  LOGIN_EMAIL_REJECTION_LIMIT = 10
  LOGIN_EMAIL_REJECTION_PERIOD = 15.minutes
  RATE_LIMIT_ERROR_MESSAGE = "Too many blocked email attempts. Please wait a few minutes and try again."

  private

  # A user who reached the limit can't change any email until the cooldown
  # ends, whatever the address, so a 429 never tells a login address apart
  # from an unused one. Checked before validation, and only for real changes.
  def login_email_cooldown_active?
    return false unless current_user&.id

    window = login_email_rejection_window
    login_email_rejection_count(window) >= LOGIN_EMAIL_REJECTION_LIMIT ||
      login_email_rejection_count(window - 1) >= LOGIN_EMAIL_REJECTION_LIMIT
  end

  def contact_email_submitted_in_request?
    params[:employee].respond_to?(:key?) && params[:employee][:email].present?
  end

  def render_login_email_cooldown!
    response.set_header("Retry-After", login_email_cooldown_retry_after.to_s)
    render json: {
      error: RATE_LIMIT_ERROR_MESSAGE,
      code: "contact_email_rate_limited"
    }, status: :too_many_requests
  end

  def render_contact_validation_error!(error, employee: nil)
    result = error.result
    if result&.login_email_rejected? && current_user&.id
      count = login_email_rejection_count(login_email_rejection_window, 1)
      # Only concurrent requests can pass the cooldown check past the limit.
      rate_limited = count > LOGIN_EMAIL_REJECTION_LIMIT

      record_login_email_rejection_audit!(result: result, employee: employee, rejection_count: count, rate_limited: rate_limited)

      return render_login_email_cooldown! if rate_limited
    end

    render json: {
      error: "Validation failed",
      details: error.record.errors.messages,
      contact_validation: result.contact_validation_payload
    }, status: :unprocessable_entity
  end

  def record_login_email_rejection_audit!(result:, employee:, rejection_count:, rate_limited:)
    normalized_email = result.normalized_email
    AuditLog.record!(
      user: current_user,
      organization_id: current_company&.organization_id || current_user.organization_id,
      company_id: current_company&.id,
      action: "employees#login_email_rejected",
      record_type: "employees",
      record_id: employee&.persisted? ? employee.id : nil,
      subject_name: employee&.display_name.presence || "Employee contact update",
      metadata: {
        rejection_reason: result.login_email_rejection_reason,
        attempted_email_domain: normalized_email&.split("@", 2)&.last,
        attempted_email_digest: normalized_email.present? ? Digest::SHA256.hexdigest(normalized_email) : nil,
        rejection_count: rejection_count,
        rate_limited: rate_limited,
        endpoint: "#{controller_path}##{action_name}"
      }.compact,
      ip_address: request.remote_ip,
      user_agent: request.user_agent,
      request_id: request.request_id,
      event_category: "security"
    )
  rescue StandardError => e
    Rails.logger.error("[EmployeeContactLoginRejectionGuard] Failed to record rejection audit: #{e.class}: #{e.message}")
  end

  # Counts rejections with the same shared-or-local counter Rack::Attack uses,
  # one fixed window per user. Adding 0 reads the count. Each window's key
  # lives through the next window, which the cooldown also covers.
  def login_email_rejection_count(window, amount = 0)
    key = "employee-contact-login-reject/user/#{current_user.id}/#{window}"
    Rack::Attack.cache.store.increment(key, amount, expires_in: 2 * LOGIN_EMAIL_REJECTION_PERIOD.to_i).to_i
  end

  def login_email_rejection_window
    Time.now.to_i / LOGIN_EMAIL_REJECTION_PERIOD.to_i
  end

  def login_email_cooldown_retry_after
    period = LOGIN_EMAIL_REJECTION_PERIOD.to_i
    remaining = period - (Time.now.to_i % period)
    login_email_rejection_count(login_email_rejection_window) >= LOGIN_EMAIL_REJECTION_LIMIT ? remaining + period : remaining
  end
end
