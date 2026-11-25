# frozen_string_literal: true

require "cgi"

module EmployeeLinks
  # Security notice sent to the employee's email address ON FILE (captured
  # before activation changes any contact details) whenever their employee app
  # link becomes active. Carries only the employer name and activation date in
  # Guam time — never pay data or sign-in credentials.
  module ActivationNoticeEmail
    CHANNEL = "employee_link_activation_notice"
    GUAM_TIME_ZONE = "Pacific/Guam"

    module_function

    # Returns :sent, :captured, :skipped or :failed. Never raises into activation.
    def deliver(link:, email_on_file:, activated_at: nil)
      return :skipped unless PortalNotifications.delivery_enabled? && PortalNotifications::Transport.configured?

      to = EmployeeLinks.normalized_email(email_on_file)
      return :skipped unless EmployeeLinks.email_format?(to)
      return :skipped unless DemoOutbound.permit?(company: link.company, email: to, channel: CHANNEL)

      timestamp = activated_at || link.activated_at || Time.current
      response = DemoOutbound.scoped(link.company, channel: CHANNEL) do
        PortalNotifications::Transport.deliver(
          payload(link, to, timestamp),
          idempotency_key: "employee-link-activated-#{link.id}-#{timestamp.to_i}"
        )
      end
      return :skipped if response["suppressed"]

      response["captured"] || response["staging_captured"] ? :captured : :sent
    rescue StandardError => error
      Rails.logger.warn("[EmployeeLinks::ActivationNoticeEmail] Activation notice for link #{link.id} failed: #{error.class}")
      :failed
    end

    def payload(link, to, activated_at)
      employer = link.company.name
      date_guam = activated_at.in_time_zone(GUAM_TIME_ZONE).strftime("%B %-d, %Y")
      lines = [
        "Your #{employer} employee app account was set up on #{date_guam}.",
        "If this wasn't you, contact #{employer}/Cornerstone."
      ]
      {
        from: PortalNotifications::Transport.from_email,
        to: to,
        subject: "Your #{employer} employee app account was set up",
        text: lines.join(" "),
        html: lines.map { |line| "<p>#{CGI.escapeHTML(line)}</p>" }.join
      }
    end
  end
end
