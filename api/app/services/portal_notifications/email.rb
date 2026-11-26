# frozen_string_literal: true

require "cgi"

module PortalNotifications
  # Portal notification emails. General portal alerts stay deliberately generic
  # (no names, subjects, message bodies, file names or amounts). Payroll review
  # emails (payroll_review_published, payroll_review_decided) use the branded
  # #620 table layout and name only the client, pay period dates, and a
  # company-scoped deep link — never amounts, employee names or reasons.
  class Email
    SUBJECT = "New activity in Cornerstone Payroll"
    MESSAGE_LINE = "You have a new message in the portal."
    UPDATE_LINE = "You have a new message or update in the portal."
    DIGEST_LINE = "You have updates waiting in Cornerstone Payroll."
    EMPLOYEE_FOOTER_LINE = "Replies to this email are not monitored."
    SIGN_IN_LINE = "Sign in to view it."
    FOOTER_LINE = "Please reply in the portal. Replies to this email are not monitored. " \
      "You can change these alerts under Notifications in your account menu."
    # Extra addresses belong to people without an account menu.
    EXTRA_ADDRESS_FOOTER_LINE = "Replies to this email are not monitored. " \
      "Contact Cornerstone to change who receives these alerts."
    CORNERSTONE_BLUE = "#194baa"

    FILE_REQUEST_EVENTS = %w[file_requested file_request_responded file_request_reviewed].freeze
    PAYROLL_REVIEW_EVENTS = %w[payroll_review_published payroll_review_decided].freeze

    attr_reader :subject, :lines, :link, :footer

    def initialize(audience:, delivery_mode:, events:, app_user: true)
      @footer = if audience == "employee" then EMPLOYEE_FOOTER_LINE
      elsif app_user then FOOTER_LINE
      else EXTRA_ADDRESS_FOOTER_LINE
      end

      if payroll_review_batch?(events)
        @branded_message = build_payroll_review_message(audience: audience, events: events, app_user: app_user)
        @subject = @branded_message.subject
        @lines = [ @branded_message.heading, *@branded_message.paragraphs ]
        @link = @branded_message.action&.fetch(:url, nil)
        return
      end

      @subject = SUBJECT
      headline = if delivery_mode == "digest" then DIGEST_LINE
      elsif events.all?(&:message_event?) then MESSAGE_LINE
      else UPDATE_LINE
      end
      if events.any? { |event| event.event_type == "tax_form_paper_required" }
        @subject = "Paper tax form follow-up required"
        headline = "A tax form email could not be delivered. Review the paper copy deadline in the Year-end checklist."
      end
      @lines = [ headline, SIGN_IN_LINE ]
      @link = if audience == "employee"
        self.class.employee_portal_url(events.first.company)
      else
        "#{self.class.frontend_url}#{path_for(audience, events)}"
      end
    end

    def payload(from:, to:)
      if @branded_message
        return {
          from: EmployeeEmails::Message.product_from_header(from),
          to: to,
          subject: @branded_message.subject,
          text: @branded_message.text,
          html: @branded_message.html
        }
      end

      { from: from, to: to, subject: subject, text: text, html: html }
    end

    def text
      return @branded_message.text if @branded_message

      [ *lines, "", "Open portal: #{link}", "", footer ].join("\n")
    end

    def html
      return @branded_message.html if @branded_message

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

    # The dispatcher batches only events that share a destination, so every
    # email's link reaches all the work it mentions. Digest batches split per
    # client; immediate payroll review emails split per client and pay period.
    def self.destination_group(event, delivery_mode: "immediate")
      # Keyed on the event, not its shared category: a file request is
      # answered or reviewed where the request card is.
      return [ :tax_form_paper, event.company_id, event.metadata["tax_year"] ] if event.event_type == "tax_form_paper_required"

      if event.event_type == "payroll_review_published"
        return [ :payroll_review_published, event.company_id ] if delivery_mode == "digest"

        return [ :payroll_review_published, event.company_id, pay_period_id_for(event) ]
      end

      if event.event_type == "payroll_review_decided"
        return [ :payroll_review_decided, event.company_id ] if delivery_mode == "digest"

        return [ :payroll_review_decided, event.company_id, pay_period_id_for(event), event.metadata["decision"] ]
      end

      return :file_requests if FILE_REQUEST_EVENTS.include?(event.event_type)
      return [ :contact_confirmation, event.company_id ] if event.event_type == "employee_contact_confirmation_requested"

      case event.category
      when "payroll_submissions", "payroll_updates" then :payroll
      when "employee_changes", "employee_change_decisions", "address_approvals" then :changes
      when "contact_changes" then :contact_changes
      when "employee_address_decisions" then [ :employee, event.company_id ]
      else :general
      end
    end

    def self.pay_period_id_for(event)
      return event.subject_id if event.subject_type == "PayPeriod" && event.subject_id.present?

      event.metadata["pay_period_id"]
    end

    def self.employee_portal_url(company)
      EmployeeLinks::AppUrl.origin_for(company) ||
        TenantSubdomainRegistry.https_url(ENV["EMPLOYEE_PORTAL_URL"].to_s.strip.delete_suffix("/"))
    end

    def self.frontend_url
      ENV.fetch("FRONTEND_URL") { ENV.fetch("ALLOWED_ORIGINS", "http://localhost:5173").split(",").first.strip }.chomp("/")
    end

    private

    def payroll_review_batch?(events)
      events.any? && events.all? { |event| PAYROLL_REVIEW_EVENTS.include?(event.event_type) }
    end

    def build_payroll_review_message(audience:, events:, app_user:)
      company = events.first.company
      company_id = events.first.company_id
      company_name = safe_display_text(company&.name) || "your client"
      demo = company&.demo? == true
      demo_prefix = demo ? "[Demo] " : ""
      periods = resolved_pay_periods(events)
      period_ids = events.filter_map { |event| self.class.pay_period_id_for(event) }.uniq
      single_period = periods.one? ? periods.first : nil
      single_period_id = period_ids.one? ? period_ids.first : nil
      period_text = format_period_range(single_period)
      pay_date_text = single_period&.pay_date&.strftime("%b %-d, %Y")
      url = payroll_review_url(audience: audience, company_id: company_id, pay_period_id: single_period_id)
      subtitle = audience == "staff" ? "Account team" : "Client portal"
      brand = EmployeeEmails::Brand.new(
        name: EmployeeEmails::Message::PRODUCT,
        app_name: subtitle,
        logo_url: nil,
        primary_color: CORNERSTONE_BLUE,
        help_email: nil
      )

      copy = if events.all? { |event| event.event_type == "payroll_review_published" }
        published_copy(
          demo_prefix: demo_prefix, company_name: company_name, periods: periods,
          single_period: single_period, period_text: period_text, pay_date_text: pay_date_text, url: url
        )
      else
        decided_copy(
          demo_prefix: demo_prefix, company_name: company_name, events: events, periods: periods,
          single_period: single_period, period_text: period_text, pay_date_text: pay_date_text, url: url
        )
      end

      footer_lines = [ copy.fetch(:privacy_line) ]
      footer_lines << "Demo company. Not a real payroll record." if demo
      footer_lines << (app_user ? FOOTER_LINE : EXTRA_ADDRESS_FOOTER_LINE)

      EmployeeEmails::Message.new(
        brand: brand,
        subject: copy.fetch(:subject),
        preheader: copy.fetch(:preheader),
        heading: copy.fetch(:heading),
        paragraphs: copy.fetch(:paragraphs),
        action: copy.fetch(:action),
        footer_lines: footer_lines
      )
    end

    def published_copy(demo_prefix:, company_name:, periods:, single_period:, period_text:, pay_date_text:, url:)
      if single_period && period_text
        paragraphs = [
          "Cornerstone Payroll prepared the payroll preview for #{company_name} for the pay period #{period_text}.",
          ("Pay date: #{pay_date_text}." if pay_date_text),
          "Sign in to review the preview and approve it or request changes."
        ].compact
        {
          subject: "#{demo_prefix}Payroll ready for approval — #{company_name} (#{period_text})",
          preheader: "Review and approve payroll for #{company_name} (#{period_text}).",
          heading: "Payroll is ready for your approval",
          paragraphs: paragraphs,
          action: { label: "Review payroll", url: url },
          privacy_line: "Amounts and employee details stay behind sign-in."
        }
      else
        period_labels = periods.filter_map { |period| format_period_range(period) }.uniq
        paragraphs = [
          "Cornerstone Payroll prepared #{periods.size > 1 ? "#{periods.size} payroll previews" : "a payroll preview"} for #{company_name}.",
          ("Pay periods: #{period_labels.join(', ')}." if period_labels.any?),
          "Sign in to review and approve payroll in Cornerstone Payroll."
        ].compact
        {
          subject: "#{demo_prefix}Payroll ready for approval — #{company_name}",
          preheader: "Payroll previews are ready for your review for #{company_name}.",
          heading: "Payroll is ready for your approval",
          paragraphs: paragraphs,
          action: { label: "Review payroll", url: url },
          privacy_line: "Amounts and employee details stay behind sign-in."
        }
      end
    end

    def decided_copy(demo_prefix:, company_name:, events:, periods:, single_period:, period_text:, pay_date_text:, url:)
      decisions = events.filter_map { |event| event.metadata["decision"] }.uniq

      if single_period && period_text && decisions == [ "approved" ]
        paragraphs = [
          "#{company_name} approved the payroll preview for the pay period #{period_text}.",
          ("Pay date: #{pay_date_text}." if pay_date_text),
          "Sign in to open the pay run and continue processing."
        ].compact
        {
          subject: "#{demo_prefix}Client approved payroll — #{company_name} (#{period_text})",
          preheader: "#{company_name} approved payroll for #{period_text}.",
          heading: "Client approved payroll",
          paragraphs: paragraphs,
          action: { label: "Open pay run", url: url },
          privacy_line: "Amounts, employee details, and approval notes stay behind sign-in."
        }
      elsif single_period && period_text && decisions == [ "changes_requested" ]
        paragraphs = [
          "#{company_name} requested changes to the payroll preview for the pay period #{period_text}.",
          ("Pay date: #{pay_date_text}." if pay_date_text),
          "Sign in to view the request and update the pay run."
        ].compact
        {
          subject: "#{demo_prefix}Changes requested on payroll — #{company_name} (#{period_text})",
          preheader: "#{company_name} requested changes on payroll for #{period_text}.",
          heading: "Client requested payroll changes",
          paragraphs: paragraphs,
          action: { label: "Open pay run", url: url },
          privacy_line: "Amounts, employee details, and change-request notes stay behind sign-in."
        }
      else
        period_labels = periods.filter_map { |period| format_period_range(period) }.uniq
        subject_suffix = period_text ? " (#{period_text})" : ""
        paragraphs = [
          "#{company_name} recorded payroll review updates in Cornerstone Payroll.",
          ("Pay periods: #{period_labels.join(', ')}." if period_labels.any?),
          "Sign in to review the client's decision and continue processing."
        ].compact
        {
          subject: "#{demo_prefix}Payroll review updates — #{company_name}#{subject_suffix}",
          preheader: "Client payroll review updates are waiting for #{company_name}.",
          heading: "Payroll review updates",
          paragraphs: paragraphs,
          action: { label: single_period ? "Open pay run" : "Open pay runs", url: url },
          privacy_line: "Amounts, employee details, and client notes stay behind sign-in."
        }
      end
    end

    def resolved_pay_periods(events)
      loaded = []
      missing_ids = []
      events.each do |event|
        if event.subject.is_a?(PayPeriod)
          loaded << event.subject
        elsif (period_id = self.class.pay_period_id_for(event)).present?
          missing_ids << period_id
        end
      end
      if missing_ids.any? && events.first.company_id.present?
        loaded.concat(PayPeriod.where(company_id: events.first.company_id, id: missing_ids.uniq).to_a)
      end
      loaded.uniq(&:id)
    end

    def payroll_review_url(audience:, company_id:, pay_period_id:)
      base = self.class.frontend_url
      return "#{base}/pay-periods" unless company_id.present?
      return "#{base}/companies/#{company_id}/pay-runs" unless pay_period_id.present?

      tab = audience == "staff" ? "work" : "overview"
      "#{base}/companies/#{company_id}/pay-runs/#{pay_period_id}/#{tab}"
    end

    def format_period_range(pay_period)
      return unless pay_period&.start_date && pay_period&.end_date

      if pay_period.start_date.year == pay_period.end_date.year
        "#{pay_period.start_date.strftime('%b %-d')} – #{pay_period.end_date.strftime('%b %-d, %Y')}"
      else
        "#{pay_period.start_date.strftime('%b %-d, %Y')} – #{pay_period.end_date.strftime('%b %-d, %Y')}"
      end
    end

    def safe_display_text(value)
      value.to_s.gsub(EmployeeEmails::Message::UNSAFE_HEADER_CHARACTERS, " ").squish.presence
    end

    def path_for(audience, events)
      groups = events.map { |event| self.class.destination_group(event) }.uniq
      group = groups.one? ? groups.first : :general
      if group.is_a?(Array) && group.first == :contact_confirmation
        return "/companies/#{group.last}/contact-changes-to-confirm"
      end

      if group.is_a?(Array) && group.first == :tax_form_paper
        return "/companies/#{group[1]}/year-end?year=#{group[2]}"
      end

      case [ audience == "staff", group ]
      when [ true, :pay_runs ], [ false, :pay_runs ] then "/pay-periods"
      when [ true, :payroll ], [ true, :file_requests ] then "/app/client-inbox"
      when [ false, :file_requests ] then "/messages"
      when [ false, :payroll ] then "/payroll-files"
      when [ true, :changes ] then "/settings/client-change-requests"
      when [ false, :contact_changes ] then "/change-requests?view=contact"
      when [ false, :changes ] then "/change-requests"
      when [ true, :general ] then "/settings/client-documents"
      else "/documents"
      end
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
    end
  end
end
