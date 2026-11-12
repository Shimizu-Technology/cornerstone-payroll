# frozen_string_literal: true

require "cgi"

module PortalNotifications
  # Deliberately generic. No company, employee, conversation subject, message
  # text, file name, amount, identifier or signed URL ever appears here.
  class Email
    SUBJECT = "New activity in Cornerstone Payroll"
    MESSAGE_LINE = "You have a new message in the portal."
    UPDATE_LINE = "You have a new message or update in the portal."
    DIGEST_LINE = "You have updates waiting in Cornerstone Payroll."
    SIGN_IN_LINE = "Sign in to view it."
    FOOTER_LINE = "Please reply in the portal. Replies to this email are not monitored. " \
      "You can change these alerts under Notifications in your account menu."
    # Extra addresses belong to people without an account menu.
    EXTRA_ADDRESS_FOOTER_LINE = "Replies to this email are not monitored. " \
      "Contact Cornerstone to change who receives these alerts."

    attr_reader :subject, :lines, :link, :footer

    def initialize(audience:, delivery_mode:, events:, app_user: true)
      @subject = SUBJECT
      @footer = app_user ? FOOTER_LINE : EXTRA_ADDRESS_FOOTER_LINE
      headline = if delivery_mode == "digest" then DIGEST_LINE
      elsif events.all?(&:message_event?) then MESSAGE_LINE
      else UPDATE_LINE
      end
      @lines = [ headline, SIGN_IN_LINE ]
      @link = "#{self.class.frontend_url}#{path_for(audience, events)}"
    end

    def payload(from:, to:)
      { from: from, to: to, subject: subject, text: text, html: html }
    end

    def text
      [ *lines, "", "Open portal: #{link}", "", footer ].join("\n")
    end

    def html
      <<~HTML
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>#{h(subject)}</title></head>
          <body style="margin:0;padding:0;background-color:#f3f4f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;">
            <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color:#f3f4f6;">
              <tr><td align="center" style="padding:40px 16px;">
                <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:500px;background-color:#ffffff;border:1px solid #e5e7eb;border-radius:12px;">
                  <tr><td style="padding:32px 32px 0 32px;font-size:18px;font-weight:700;color:#111827;">Cornerstone Payroll</td></tr>
                  <tr><td style="padding:16px 32px 0 32px;font-size:15px;line-height:1.6;color:#374151;">#{lines.map { |line| h(line) }.join('<br>')}</td></tr>
                  <tr><td style="padding:24px 32px 0 32px;">
                    <a href="#{h(link)}" style="display:inline-block;padding:12px 28px;background-color:#2563eb;border-radius:6px;color:#ffffff;text-decoration:none;font-size:14px;font-weight:700;">Open portal</a>
                  </td></tr>
                  <tr><td style="padding:24px 32px 32px 32px;font-size:12px;line-height:1.6;color:#6b7280;">#{h(footer)}</td></tr>
                </table>
              </td></tr>
            </table>
          </body>
        </html>
      HTML
    end

    def self.frontend_url
      ENV.fetch("FRONTEND_URL") { ENV.fetch("ALLOWED_ORIGINS", "http://localhost:5173").split(",").first.strip }.chomp("/")
    end

    private

    def path_for(audience, events)
      change_only = events.all? { |event| event.category.in?(%w[employee_changes employee_change_decisions]) }
      if events.all? { |event| event.category.in?(%w[payroll_submissions payroll_updates]) }
        return audience == "staff" ? "/app/client-inbox" : "/payroll-files"
      end
      if audience == "staff"
        change_only ? "/settings/client-change-requests" : "/settings/client-documents"
      else
        change_only ? "/change-requests" : "/documents"
      end
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
    end
  end
end
