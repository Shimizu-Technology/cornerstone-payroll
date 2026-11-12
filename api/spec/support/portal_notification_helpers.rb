# frozen_string_literal: true

# Captures the portal notification transport. No spec sends real email.
module PortalNotificationHelpers
  PORTAL_EMAIL_ENV = %w[PORTAL_EMAIL_NOTIFICATIONS_ENABLED PORTAL_EMAIL_TRANSPORT PORTAL_EMAIL_CAPTURE_PATH RESEND_FROM_EMAIL FRONTEND_URL].freeze

  def with_portal_email(enabled: true, transport: "capture", from: "alerts@example.test")
    saved = PORTAL_EMAIL_ENV.to_h { |name| [ name, ENV[name] ] }
    ENV["PORTAL_EMAIL_NOTIFICATIONS_ENABLED"] = enabled ? "true" : nil
    ENV["PORTAL_EMAIL_TRANSPORT"] = transport
    ENV["PORTAL_EMAIL_CAPTURE_PATH"] = nil
    ENV["RESEND_FROM_EMAIL"] = from
    ENV["FRONTEND_URL"] = "https://payroll.example.test"
    PortalNotifications::Transport.clear_captured!
    yield
  ensure
    saved.each { |name, value| ENV[name] = value }
    PortalNotifications::Transport.clear_captured!
  end

  def captured_portal_emails
    PortalNotifications::Transport.captured
  end

  def list_portal_recipient!(company, user: nil, email: nil)
    PortalNotificationRecipient.create!(company: company, user: user, email: email)
  end
end

RSpec.configure do |config|
  config.include PortalNotificationHelpers
  # Tagged specs can never reach the real provider.
  config.before(:each, :portal_notifications) do
    allow(Resend::Emails).to receive(:send).and_raise("Real email is disabled in portal notification specs")
  end
end
