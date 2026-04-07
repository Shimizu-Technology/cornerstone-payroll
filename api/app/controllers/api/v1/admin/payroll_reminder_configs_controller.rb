# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollReminderConfigsController < BaseController
        # GET /api/v1/admin/payroll_reminder_config
        def show
          config = current_company.payroll_reminder_config || current_company.build_payroll_reminder_config
          render json: { payroll_reminder_config: serialize(config) }
        end

        # PUT /api/v1/admin/payroll_reminder_config
        def update
          config = current_company.payroll_reminder_config || current_company.build_payroll_reminder_config

          if config.update(config_params)
            render json: { payroll_reminder_config: serialize(config) }
          else
            render json: { errors: config.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # POST /api/v1/admin/payroll_reminder_config/test
        def test
          config = current_company.payroll_reminder_config
          unless config&.enabled? && config.recipients.present?
            return render json: { error: "Reminders must be enabled with at least one recipient" }, status: :unprocessable_entity
          end

          unless ENV["RESEND_API_KEY"].present?
            return render json: { error: "Email service not configured" }, status: :unprocessable_entity
          end

          from_email = ENV["RESEND_FROM_EMAIL"].presence || ENV["MAILER_FROM_EMAIL"].presence
          unless from_email.present?
            return render json: { error: "From email not configured" }, status: :unprocessable_entity
          end

          config.recipients.each do |email|
            Resend::Emails.send({
              from: from_email,
              to: email,
              subject: "Test: Payroll Reminder for #{current_company.name}",
              html: test_email_html
            })
          end

          render json: { message: "Test email sent to #{config.recipients.size} recipient(s)" }
        rescue StandardError => e
          render json: { error: "Failed to send test email: #{e.message}" }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/payroll_reminder_config/logs
        def logs
          logs = current_company.payroll_reminder_logs
                                .includes(:pay_period)
                                .order(sent_at: :desc)
                                .limit(50)

          render json: {
            logs: logs.map { |log|
              entry = {
                id: log.id,
                reminder_type: log.reminder_type,
                sent_at: log.sent_at,
                recipients_snapshot: log.recipients_snapshot,
                expected_pay_date: log.expected_pay_date
              }

              if log.pay_period
                entry[:pay_period] = {
                  id: log.pay_period.id,
                  start_date: log.pay_period.start_date,
                  end_date: log.pay_period.end_date,
                  pay_date: log.pay_period.pay_date,
                  status: log.pay_period.status
                }
              end

              entry
            }
          }
        end

        private

        def config_params
          params.require(:payroll_reminder_config).permit(:enabled, :days_before_due, :send_overdue_alerts, recipients: [])
        end

        def serialize(config)
          {
            id: config.id,
            enabled: config.enabled,
            recipients: config.recipients || [],
            days_before_due: config.days_before_due,
            send_overdue_alerts: config.send_overdue_alerts,
            created_at: config.created_at,
            updated_at: config.updated_at
          }
        end

        def test_email_html
          <<~HTML
            <!doctype html>
            <html>
              <head><meta charset="utf-8"></head>
              <body style="margin: 0; padding: 0; background-color: #f3f4f6; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif;">
                <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #f3f4f6;">
                  <tr>
                    <td align="center" style="padding: 40px 16px;">
                      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width: 500px; background-color: #ffffff; border: 1px solid #e5e7eb; border-radius: 12px; overflow: hidden;">
                        <tr><td style="height: 4px; background: linear-gradient(90deg, #2563eb, #3b82f6); font-size: 0;">&nbsp;</td></tr>
                        <tr>
                          <td style="padding: 32px; text-align: center;">
                            <p style="margin: 0 0 8px 0; color: #22c55e; font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase; font-weight: 700;">Test Successful</p>
                            <h1 style="margin: 0 0 12px 0; color: #111827; font-size: 22px; font-weight: 700;">Payroll Reminders Are Working</h1>
                            <p style="margin: 0; font-size: 14px; line-height: 1.7; color: #6b7280;">
                              This is a test email from <strong style="color: #111827;">Cornerstone Payroll</strong> confirming that
                              payroll reminders are properly configured for <strong style="color: #111827;">#{CGI.escapeHTML(current_company.name)}</strong>.
                            </p>
                          </td>
                        </tr>
                      </table>
                    </td>
                  </tr>
                </table>
              </body>
            </html>
          HTML
        end
      end
    end
  end
end
