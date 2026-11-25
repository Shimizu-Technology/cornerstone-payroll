# frozen_string_literal: true

require "cgi"

module EmployeeLinks
  # The invite email. It carries the employer's name and a one-time link, and
  # nothing about pay. Real email stays off unless
  # PORTAL_EMAIL_NOTIFICATIONS_ENABLED=true; a skipped invite is resent later.
  module InviteEmail
    SUBJECT = "You're invited to your employee app"

    module_function

    # Returns :sent, :captured, :skipped or :failed.
    def deliver(link:, token:, path:)
      return :skipped unless PortalNotifications.delivery_enabled? && PortalNotifications::Transport.configured?

      url = AppUrl.invite_url(link.company, path: path, secret: token)
      to = link.invite_email
      return :failed unless url && to
      return :skipped unless DemoOutbound.permit?(company: link.company, email: to, channel: "employee_link_invite")

      response = DemoOutbound.scoped(link.company) do
        PortalNotifications::Transport.deliver(payload(link, url, path, to),
          idempotency_key: "employee-link-invite-#{link.id}-#{link.invite_token_digest.first(16)}")
      end
      return :skipped if response["suppressed"]

      response["captured"] || response["staging_captured"] ? :captured : :sent
    rescue StandardError => error
      Rails.logger.warn("[EmployeeLinks::InviteEmail] Invite email for link #{link.id} failed: #{error.class}")
      :failed
    end

    def payload(link, url, path, to)
      employer = link.company.name
      action = path == "sign_up" ? "Set up your account" : "Sign in to add your employee access"
      lines = [
        "#{employer} invited you to see your pay stubs and update your contact details in the employee app.",
        "#{action}: #{url}",
        "This link works once and expires in 14 days. If you weren't expecting it, you can ignore this email."
      ]
      {
        from: PortalNotifications::Transport.from_email, to: to, subject: SUBJECT,
        text: lines.join("\n\n"),
        html: lines.map { |line| "<p>#{CGI.escapeHTML(line)}</p>" }.join
      }
    end
  end
end
