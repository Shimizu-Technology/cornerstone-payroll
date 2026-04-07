# frozen_string_literal: true

require "cgi"

class PayrollReminderService
  BRAND_NAME = "Cornerstone Payroll"

  FREQUENCY_DAYS = {
    "weekly" => 7,
    "biweekly" => 14,
    "semimonthly" => nil,
    "monthly" => nil
  }.freeze

  class << self
    # Main entry point: called daily by SendPayrollRemindersJob.
    def run_all!
      return unless email_configured?

      PayrollReminderConfig.where(enabled: true).includes(:company).find_each do |config|
        process_company(config)
      rescue StandardError => e
        Rails.logger.error("[PayrollReminder] Error for company #{config.company_id}: #{e.class} #{e.message}")
      end
    end

    private

    # -----------------------------------------------------------------------
    # Core scheduling logic
    # -----------------------------------------------------------------------

    def process_company(config)
      company = config.company
      return if config.recipients.blank?

      today = Date.current
      deadline = today + config.days_before_due.days

      # 1) "Create payroll" — no pay period exists yet for the next expected cycle
      check_create_payroll(config, company, today)

      # 2) "Upcoming" — pay period exists but hasn't been committed, pay_date approaching
      upcoming_periods = company.pay_periods
                                .where(status: %w[draft calculated])
                                .where(correction_status: [nil, "correction"])
                                .where(pay_date: today..deadline)

      upcoming_periods.find_each do |pp|
        send_period_reminder(config, pp, "upcoming") unless already_sent_for_period?(company.id, pp.id, "upcoming")
      end

      # 3) "Overdue" — pay_date has passed, still not committed
      return unless config.send_overdue_alerts

      overdue_periods = company.pay_periods
                               .where(status: %w[draft calculated])
                               .where(correction_status: [nil, "correction"])
                               .where("pay_date < ?", today)

      overdue_periods.find_each do |pp|
        send_period_reminder(config, pp, "overdue") unless already_sent_for_period?(company.id, pp.id, "overdue")
      end
    end

    def check_create_payroll(config, company, today)
      last_period = company.pay_periods
                           .where(correction_status: [nil, "correction"])
                           .order(end_date: :desc)
                           .first

      return unless last_period

      expected = calculate_next_period(company.pay_frequency, last_period)
      return unless expected

      expected_pay_date = expected[:pay_date]

      # Is it time to remind? (within the days_before_due window of the expected pay_date)
      reminder_trigger_date = expected_pay_date - config.days_before_due.days
      return unless today >= reminder_trigger_date

      # Does a pay period already exist that covers this expected range?
      existing = company.pay_periods
                        .where(correction_status: [nil, "correction"])
                        .where("start_date <= ? AND end_date >= ?", expected[:end_date], expected[:start_date])
      return if existing.exists?

      # Already sent this specific create reminder?
      return if already_sent_create_reminder?(company.id, expected_pay_date)

      send_create_reminder(config, company, expected)
    end

    def calculate_next_period(frequency, last_period)
      pay_offset = (last_period.pay_date - last_period.end_date).to_i
      next_start = last_period.end_date + 1.day

      case frequency
      when "weekly"
        next_end = next_start + 6.days
      when "biweekly"
        next_end = next_start + 13.days
      when "semimonthly"
        if next_start.day <= 15
          next_end = Date.new(next_start.year, next_start.month, 15)
        else
          next_end = next_start.end_of_month
        end
      when "monthly"
        next_end = next_start.end_of_month
      else
        return nil
      end

      next_pay_date = next_end + [pay_offset, 0].max.days

      { start_date: next_start, end_date: next_end, pay_date: next_pay_date }
    end

    # -----------------------------------------------------------------------
    # Sending helpers
    # -----------------------------------------------------------------------

    def send_period_reminder(config, pay_period, reminder_type)
      company = config.company

      case reminder_type
      when "overdue"
        html = overdue_html(company: company, pay_period: pay_period)
        subject = "⚠️ Overdue: Payroll for #{company.name} (#{pay_period.period_description})"
      else
        html = upcoming_html(company: company, pay_period: pay_period, days_before: config.days_before_due)
        subject = "📋 Reminder: Payroll due for #{company.name} (#{pay_period.period_description})"
      end

      deliver_to_recipients(config, subject, html)

      PayrollReminderLog.create!(
        company_id: company.id,
        pay_period_id: pay_period.id,
        reminder_type: reminder_type,
        recipients_snapshot: config.recipients,
        sent_at: Time.current
      )

      Rails.logger.info("[PayrollReminder] Sent #{reminder_type} for company=#{company.id} pay_period=#{pay_period.id}")
    rescue ActiveRecord::RecordNotUnique
      Rails.logger.info("[PayrollReminder] Duplicate #{reminder_type} skipped for company=#{company.id} pay_period=#{pay_period.id}")
    rescue StandardError => e
      Rails.logger.error("[PayrollReminder] Failed #{reminder_type} for company=#{company.id} pay_period=#{pay_period.id}: #{e.class} #{e.message}")
    end

    def send_create_reminder(config, company, expected)
      html = create_payroll_html(company: company, expected: expected)
      freq_label = company.pay_frequency.gsub("semimonthly", "semi-monthly").capitalize
      subject = "📅 Time to create #{freq_label} payroll for #{company.name}"

      deliver_to_recipients(config, subject, html)

      PayrollReminderLog.create!(
        company_id: company.id,
        pay_period_id: nil,
        reminder_type: "create_payroll",
        expected_pay_date: expected[:pay_date],
        recipients_snapshot: config.recipients,
        sent_at: Time.current
      )

      Rails.logger.info("[PayrollReminder] Sent create_payroll for company=#{company.id} expected_pay_date=#{expected[:pay_date]}")
    rescue ActiveRecord::RecordNotUnique
      Rails.logger.info("[PayrollReminder] Duplicate create_payroll skipped for company=#{company.id} expected_pay_date=#{expected[:pay_date]}")
    rescue StandardError => e
      Rails.logger.error("[PayrollReminder] Failed create_payroll for company=#{company.id}: #{e.class} #{e.message}")
    end

    def deliver_to_recipients(config, subject, html)
      config.recipients.each do |email|
        Resend::Emails.send({
          from: from_email,
          to: email,
          subject: subject,
          html: html
        })
      end
    end

    # -----------------------------------------------------------------------
    # Dedup checks
    # -----------------------------------------------------------------------

    def already_sent_for_period?(company_id, pay_period_id, reminder_type)
      PayrollReminderLog.exists?(
        company_id: company_id,
        pay_period_id: pay_period_id,
        reminder_type: reminder_type
      )
    end

    def already_sent_create_reminder?(company_id, expected_pay_date)
      PayrollReminderLog.exists?(
        company_id: company_id,
        pay_period_id: nil,
        reminder_type: "create_payroll",
        expected_pay_date: expected_pay_date
      )
    end

    # -----------------------------------------------------------------------
    # Config helpers
    # -----------------------------------------------------------------------

    def email_configured?
      if ENV["RESEND_API_KEY"].blank?
        Rails.logger.warn("[PayrollReminder] RESEND_API_KEY not configured; skipping reminders")
        return false
      end

      if from_email.blank?
        Rails.logger.warn("[PayrollReminder] RESEND_FROM_EMAIL not configured; skipping reminders")
        return false
      end

      true
    end

    def from_email
      ENV["RESEND_FROM_EMAIL"].presence || ENV["MAILER_FROM_EMAIL"].presence
    end

    def frontend_url
      ENV.fetch("FRONTEND_URL") { ENV.fetch("ALLOWED_ORIGINS", "http://localhost:5173").split(",").first.strip }
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
    end

    # -----------------------------------------------------------------------
    # Email templates
    # -----------------------------------------------------------------------

    def create_payroll_html(company:, expected:)
      freq_label = company.pay_frequency.gsub("semimonthly", "semi-monthly")
      pay_periods_link = "#{frontend_url}/pay-periods"

      email_wrapper do
        <<~CONTENT
          <!-- Badge -->
          <tr>
            <td style="padding: 28px 32px 0 32px; text-align: center;">
              <span style="display: inline-block; padding: 4px 12px; background-color: #dbeafe; color: #1e40af; font-size: 11px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; border-radius: 9999px;">
                New #{h(freq_label)} Pay Period
              </span>
            </td>
          </tr>

          <!-- Heading -->
          <tr>
            <td style="padding: 20px 32px 0 32px; text-align: center;">
              <h1 style="margin: 0; color: #111827; font-size: 22px; line-height: 1.4; font-weight: 700;">
                Time to Create Payroll
              </h1>
            </td>
          </tr>

          <!-- Body -->
          <tr>
            <td style="padding: 16px 32px 0 32px; text-align: center;">
              <p style="margin: 0; font-size: 14px; line-height: 1.7; color: #6b7280;">
                It's time to create the next #{h(freq_label)} pay period for
                <strong style="color: #111827;">#{h(company.name)}</strong>.
                Based on your payroll schedule, the next expected dates are:
              </p>
            </td>
          </tr>

          <!-- Expected dates box -->
          <tr>
            <td style="padding: 20px 32px 0 32px;">
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px;">
                <tr>
                  <td style="padding: 16px;">
                    <table role="presentation" width="100%" cellspacing="0" cellpadding="0">
                      <tr>
                        <td style="padding: 4px 0; font-size: 13px; color: #6b7280; width: 50%;">Period:</td>
                        <td style="padding: 4px 0; font-size: 13px; color: #111827; font-weight: 600;">
                          #{h(expected[:start_date].strftime('%m/%d/%Y'))} – #{h(expected[:end_date].strftime('%m/%d/%Y'))}
                        </td>
                      </tr>
                      <tr>
                        <td style="padding: 4px 0; font-size: 13px; color: #6b7280;">Expected Pay Date:</td>
                        <td style="padding: 4px 0; font-size: 13px; color: #111827; font-weight: 600;">
                          #{h(expected[:pay_date].strftime('%B %d, %Y'))}
                        </td>
                      </tr>
                      <tr>
                        <td style="padding: 4px 0; font-size: 13px; color: #6b7280;">Frequency:</td>
                        <td style="padding: 4px 0; font-size: 13px; color: #111827; font-weight: 600;">
                          #{h(freq_label.capitalize)}
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- CTA -->
          <tr>
            <td style="padding: 24px 32px 0 32px;" align="center">
              <table role="presentation" cellspacing="0" cellpadding="0">
                <tr>
                  <td style="border-radius: 6px; background-color: #2563eb;">
                    <a href="#{h(pay_periods_link)}" target="_blank" style="display: inline-block; padding: 13px 36px; color: #ffffff; text-decoration: none; font-size: 14px; font-weight: 700; letter-spacing: 0.01em;">
                      Go to Pay Periods
                    </a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        CONTENT
      end
    end

    def upcoming_html(company:, pay_period:, days_before:)
      days_until = (pay_period.pay_date - Date.current).to_i
      urgency_label = days_until <= 1 ? "Tomorrow" : "in #{days_until} day#{'s' if days_until != 1}"
      pay_periods_link = "#{frontend_url}/pay-periods/#{pay_period.id}"

      email_wrapper do
        <<~CONTENT
          <!-- Badge -->
          <tr>
            <td style="padding: 28px 32px 0 32px; text-align: center;">
              <span style="display: inline-block; padding: 4px 12px; background-color: #fef3c7; color: #92400e; font-size: 11px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; border-radius: 9999px;">
                Payroll Due #{h(urgency_label)}
              </span>
            </td>
          </tr>

          <!-- Heading -->
          <tr>
            <td style="padding: 20px 32px 0 32px; text-align: center;">
              <h1 style="margin: 0; color: #111827; font-size: 22px; line-height: 1.4; font-weight: 700;">
                Payroll Reminder
              </h1>
            </td>
          </tr>

          <!-- Body -->
          <tr>
            <td style="padding: 16px 32px 0 32px; text-align: center;">
              <p style="margin: 0; font-size: 14px; line-height: 1.7; color: #6b7280;">
                The payroll for <strong style="color: #111827;">#{h(company.name)}</strong> is due
                <strong style="color: #111827;">#{h(urgency_label)}</strong>
                (pay date: #{h(pay_period.pay_date.strftime('%B %d, %Y'))}).
              </p>
            </td>
          </tr>

          #{period_details_box(pay_period)}

          <!-- CTA -->
          <tr>
            <td style="padding: 24px 32px 0 32px;" align="center">
              <table role="presentation" cellspacing="0" cellpadding="0">
                <tr>
                  <td style="border-radius: 6px; background-color: #2563eb;">
                    <a href="#{h(pay_periods_link)}" target="_blank" style="display: inline-block; padding: 13px 36px; color: #ffffff; text-decoration: none; font-size: 14px; font-weight: 700; letter-spacing: 0.01em;">
                      Open Pay Period
                    </a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        CONTENT
      end
    end

    def overdue_html(company:, pay_period:)
      days_overdue = (Date.current - pay_period.pay_date).to_i
      pay_periods_link = "#{frontend_url}/pay-periods/#{pay_period.id}"

      email_wrapper do
        <<~CONTENT
          <!-- Badge -->
          <tr>
            <td style="padding: 28px 32px 0 32px; text-align: center;">
              <span style="display: inline-block; padding: 4px 12px; background-color: #fee2e2; color: #991b1b; font-size: 11px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; border-radius: 9999px;">
                Overdue — #{days_overdue} day#{'s' if days_overdue != 1} past due
              </span>
            </td>
          </tr>

          <!-- Heading -->
          <tr>
            <td style="padding: 20px 32px 0 32px; text-align: center;">
              <h1 style="margin: 0; color: #111827; font-size: 22px; line-height: 1.4; font-weight: 700;">
                Payroll Overdue
              </h1>
            </td>
          </tr>

          <!-- Body -->
          <tr>
            <td style="padding: 16px 32px 0 32px; text-align: center;">
              <p style="margin: 0; font-size: 14px; line-height: 1.7; color: #6b7280;">
                The payroll for <strong style="color: #111827;">#{h(company.name)}</strong> has not been
                committed and is <strong style="color: #dc2626;">#{days_overdue} day#{'s' if days_overdue != 1} past the pay date</strong>
                (#{h(pay_period.pay_date.strftime('%B %d, %Y'))}).
              </p>
            </td>
          </tr>

          #{period_details_box(pay_period)}

          <!-- CTA -->
          <tr>
            <td style="padding: 24px 32px 0 32px;" align="center">
              <table role="presentation" cellspacing="0" cellpadding="0">
                <tr>
                  <td style="border-radius: 6px; background-color: #dc2626;">
                    <a href="#{h(pay_periods_link)}" target="_blank" style="display: inline-block; padding: 13px 36px; color: #ffffff; text-decoration: none; font-size: 14px; font-weight: 700; letter-spacing: 0.01em;">
                      Open Pay Period
                    </a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        CONTENT
      end
    end

    def period_details_box(pay_period)
      <<~HTML
        <!-- Info box -->
        <tr>
          <td style="padding: 20px 32px 0 32px;">
            <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px;">
              <tr>
                <td style="padding: 16px;">
                  <table role="presentation" width="100%" cellspacing="0" cellpadding="0">
                    <tr>
                      <td style="padding: 4px 0; font-size: 13px; color: #6b7280; width: 50%;">Period:</td>
                      <td style="padding: 4px 0; font-size: 13px; color: #111827; font-weight: 600;">
                        #{h(pay_period.start_date.strftime('%m/%d/%Y'))} – #{h(pay_period.end_date.strftime('%m/%d/%Y'))}
                      </td>
                    </tr>
                    <tr>
                      <td style="padding: 4px 0; font-size: 13px; color: #6b7280;">Pay Date:</td>
                      <td style="padding: 4px 0; font-size: 13px; color: #111827; font-weight: 600;">
                        #{h(pay_period.pay_date.strftime('%B %d, %Y'))}
                      </td>
                    </tr>
                    <tr>
                      <td style="padding: 4px 0; font-size: 13px; color: #6b7280;">Status:</td>
                      <td style="padding: 4px 0; font-size: 13px; color: #111827; font-weight: 600;">
                        #{h(pay_period.status.capitalize)}
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
            </table>
          </td>
        </tr>
      HTML
    end

    def email_wrapper
      content = yield

      <<~HTML
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>#{h(BRAND_NAME)} — Payroll Reminder</title>
          </head>
          <body style="margin: 0; padding: 0; background-color: #f3f4f6; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif; -webkit-font-smoothing: antialiased;">
            <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #f3f4f6;">
              <tr>
                <td align="center" style="padding: 40px 16px;">

                  <!-- Card -->
                  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width: 500px; background-color: #ffffff; border: 1px solid #e5e7eb; border-radius: 12px; overflow: hidden;">

                    <!-- Brand accent -->
                    <tr><td style="height: 4px; background: linear-gradient(90deg, #2563eb, #3b82f6); font-size: 0; line-height: 0;">&nbsp;</td></tr>

                    <!-- Logo -->
                    <tr>
                      <td style="padding: 32px 32px 0 32px; text-align: center;">
                        <table role="presentation" cellspacing="0" cellpadding="0" style="margin: 0 auto;">
                          <tr>
                            <td style="width: 36px; height: 36px; background-color: #2563eb; border-radius: 8px; text-align: center; vertical-align: middle;">
                              <span style="color: #ffffff; font-weight: bold; font-size: 16px; line-height: 36px;">CP</span>
                            </td>
                            <td style="padding-left: 10px; vertical-align: middle;">
                              <span style="font-size: 18px; font-weight: 700; color: #111827;">#{h(BRAND_NAME)}</span>
                            </td>
                          </tr>
                        </table>
                      </td>
                    </tr>

                    <!-- Divider -->
                    <tr>
                      <td style="padding: 24px 32px 0 32px;">
                        <table role="presentation" width="100%" cellspacing="0" cellpadding="0">
                          <tr><td style="height: 1px; background-color: #e5e7eb; font-size: 0;">&nbsp;</td></tr>
                        </table>
                      </td>
                    </tr>

                    #{content}

                    <!-- Footer -->
                    <tr>
                      <td style="padding: 28px 32px 32px 32px;">
                        <table role="presentation" width="100%" cellspacing="0" cellpadding="0">
                          <tr><td style="height: 1px; background-color: #e5e7eb; font-size: 0;">&nbsp;</td></tr>
                        </table>
                        <p style="margin: 16px 0 0 0; font-size: 11px; line-height: 1.6; color: #6b7280; text-align: center;">
                          This is an automated payroll reminder from #{h(BRAND_NAME)}.<br>
                          To change reminder settings, visit your company's Payroll Reminders configuration.
                        </p>
                      </td>
                    </tr>

                  </table>
                  <!-- /Card -->

                </td>
              </tr>
            </table>
          </body>
        </html>
      HTML
    end
  end
end
