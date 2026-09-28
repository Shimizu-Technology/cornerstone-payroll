# frozen_string_literal: true

require "cgi"
require "mail"

class InvoiceScheduledSender
  def self.send!(id)
    schedule = InvoiceSendSchedule.find(id)
    schedule.with_lock do
      return unless schedule.status == "pending" && schedule.send_at <= Time.current
      unless schedule.invoice.open? && schedule.invoice.balance_due.positive?
        schedule.update!(status: "cancelled", last_error: "Invoice is no longer unpaid and open")
        return
      end

      schedule.update!(status: "sending", attempts: schedule.attempts + 1, claimed_at: Time.current)
    end

    invoice = schedule.invoice
    artifact = invoice.primary_artifact
    raise ArgumentError, "An issued PDF is required before sending" unless artifact&.content_type == "application/pdf"

    sender = ENV["INVOICE_MAILER_FROM_EMAIL"].presence
    raise ArgumentError, "Invoice sender email is not configured" if ENV["RESEND_API_KEY"].blank? || sender.blank?

    bytes = InvoiceArtifactStorageService.new.download(artifact)
    profile = invoice.invoice_billing_profile
    business = profile.legal_name.presence || profile.name
    subject = invoice.snapshot.dig("invoice", "email_subject").presence || "Invoice #{invoice.invoice_number} from #{business}"
    body = invoice.snapshot.dig("invoice", "email_body").presence ||
      "Please find invoice #{invoice.invoice_number} attached. The current balance is #{invoice.currency} #{format('%.2f', invoice.balance_due)}."
    message = {
      from: sender,
      to: schedule.recipients,
      subject: subject,
      text: body,
      html: "<p>#{CGI.escapeHTML(body).gsub("\n", "<br>")}</p>",
      attachments: [ { filename: artifact.filename, content: bytes.bytes } ]
    }
    message[:reply_to] = profile.email if profile.email.present? && profile.email.match?(URI::MailTo::EMAIL_REGEXP)

    response = Resend::Emails.send(message, options: { idempotency_key: "invoice-send-#{schedule.id}" })
    reference = response[:id] || response["id"]
    raise "Invoice email provider did not return a message ID" if reference.blank?

    InvoiceSendSchedule.transaction do
      schedule.lock!
      return unless schedule.status == "sending"

      sent_at = Time.current
      schedule.recipients.each do |recipient|
        delivery = invoice.deliveries.create!(
          organization: invoice.organization,
          invoice_artifact: artifact,
          channel: "email",
          recipient: recipient,
          delivered_at: sent_at,
          provider_reference: reference,
          notes: "Accepted by email provider; delivery to inbox is not confirmed",
          recorded_by: schedule.created_by
        )
        InvoiceEvent.record!(invoice: invoice, event_type: "delivery_recorded", actor: schedule.created_by,
                             occurred_at: sent_at, metadata: { delivery_id: delivery.id, send_schedule_id: schedule.id,
                                                               recipient: recipient, provider_reference: reference })
      end
      invoice.update!(sent_at: invoice.sent_at || sent_at)
      schedule.update!(status: "sent", sent_at: sent_at, provider_reference: reference, last_error: nil)
    end
  rescue StandardError => e
    # A provider response may have been lost. Keep the stable idempotency key for an explicit retry.
    schedule&.update!(status: "failed", last_error: "#{e.class}: #{e.message}".truncate(500)) if schedule&.status == "sending"
    raise
  end
end
