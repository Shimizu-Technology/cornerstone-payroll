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

      invoice = schedule.invoice
      profile = invoice.invoice_billing_profile
      business = profile.legal_name.presence || profile.name
      details = invoice.snapshot.is_a?(Hash) && invoice.snapshot["invoice"].is_a?(Hash) ? invoice.snapshot["invoice"] : {}
      subject = details["email_subject"].presence || "Invoice #{invoice.invoice_number} from #{business}"
      body = details["email_body"].presence ||
        "Please find invoice #{invoice.invoice_number} attached. The current balance is #{invoice.currency} #{format('%.2f', invoice.balance_due)}."
      reply_to = profile.email if profile.email.present? && profile.email.match?(URI::MailTo::EMAIL_REGEXP)
      claimed_at = Time.current
      schedule.update!(status: "sending", attempts: schedule.attempts + 1, claimed_at: claimed_at,
                       first_claimed_at: schedule.first_claimed_at || claimed_at,
                       rendered_subject: schedule.rendered_subject.presence || subject,
                       rendered_body: schedule.rendered_body.presence || body,
                       sender_email: schedule.sender_email.presence || ENV["INVOICE_MAILER_FROM_EMAIL"].presence,
                       reply_to_email: schedule.attempts.zero? ? reply_to : schedule.reply_to_email)
    end

    # Keep the row locked through the provider call. Stale-send recovery skips
    # locked rows, so an in-flight request cannot be offered for retry.
    schedule.with_lock do
      return unless schedule.status == "sending"

      invoice = schedule.invoice
      artifact = invoice.primary_artifact
      raise ArgumentError, "An issued PDF is required before sending" unless artifact&.content_type == "application/pdf"
      raise ArgumentError, "Invoice sender email is not configured" if ENV["RESEND_API_KEY"].blank? || schedule.sender_email.blank?

      bytes = InvoiceArtifactStorageService.new.download(artifact)
      raise ArgumentError, "Invoice artifact is unavailable" if bytes.nil?

      message = {
        from: schedule.sender_email,
        to: schedule.recipients,
        subject: schedule.rendered_subject,
        text: schedule.rendered_body,
        html: "<p>#{CGI.escapeHTML(schedule.rendered_body).gsub("\n", "<br>")}</p>",
        attachments: [ { filename: artifact.filename, content: bytes.bytes } ]
      }
      message[:reply_to] = schedule.reply_to_email if schedule.reply_to_email.present?

      response = Resend::Emails.send(message, options: { idempotency_key: "invoice-send-#{schedule.id}" })
      reference = response[:id] || response["id"]
      raise "Invoice email provider did not return a message ID" if reference.blank?

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
