# frozen_string_literal: true

require "cgi"
require "mail"

class InvoiceScheduledSender
  def self.send!(id)
    schedule = InvoiceSendSchedule.find(id)
    InvoiceSendSchedule.with_active_send_lock(id) do
      claimed = false
      begin
        schedule.with_lock do
          return unless schedule.status.in?(%w[pending queued]) && schedule.send_at <= Time.current
          unless schedule.invoice.open? && schedule.invoice.balance_due.positive?
            schedule.update!(status: "cancelled", last_error: "Invoice is no longer unpaid and open")
            return
          end

          invoice = schedule.invoice
          profile = invoice.invoice_billing_profile
          # Text reviewed in the send panel was stored on the schedule. Without
          # it, send the invoice's current email (saved text or the default).
          # The email is delivery content, so the issued snapshot isn't read.
          content = InvoiceEmailContent.for(invoice)
          subject = content[:subject]
          body = content[:body]
          reply_to = profile.email if profile.email.present? && profile.email.match?(URI::MailTo::EMAIL_REGEXP)
          claimed_at = Time.current
          schedule.update!(status: "sending", attempts: schedule.attempts + 1, claimed_at: claimed_at,
                           first_claimed_at: schedule.first_claimed_at || claimed_at,
                           rendered_subject: schedule.rendered_subject.presence || subject,
                           rendered_body: schedule.rendered_body.presence || body,
                           sender_email: schedule.sender_email.presence || ENV["INVOICE_MAILER_FROM_EMAIL"].presence,
                           reply_to_email: schedule.attempts.zero? ? reply_to : schedule.reply_to_email)
          claimed = true
        end

        # The session advisory lock remains held during I/O. Recovery checks it,
        # while the row lock and database transaction are released.
        invoice = schedule.invoice
        artifact = invoice.primary_artifact
        raise ArgumentError, "An issued PDF is required before sending" unless artifact&.content_type == "application/pdf"
        raise ArgumentError, "Invoice sender email is not configured" if !StagingMailTransport.available? || schedule.sender_email.blank?

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

        response = StagingMailTransport.deliver(message, options: { idempotency_key: "invoice-send-#{schedule.id}" })
        reference = response[:id] || response["id"]
        raise "Invoice email provider did not return a message ID" if reference.blank?

        schedule.with_lock do
          return unless schedule.status == "sending"

          if response["staging_captured"]
            InvoiceEvent.record!(invoice: invoice, event_type: "staging_mail_captured", actor: schedule.created_by,
                                 metadata: { send_schedule_id: schedule.id, recipient_count: schedule.recipients.size })
            schedule.update!(status: "cancelled", provider_reference: reference, last_error: "STAGING capture only; no email was sent")
            return
          end

          sent_at = Time.current
          recipients = StagingOutboundPolicy.staging? ? response.fetch("staging_recipients") : schedule.recipients
          recipients.each do |recipient|
            delivery = invoice.deliveries.create!(
              organization: invoice.organization,
              invoice_artifact: artifact,
              channel: "email",
              recipient: recipient,
              delivered_at: sent_at,
              provider_reference: reference,
              email_subject: schedule.rendered_subject,
              email_body: schedule.rendered_body,
              notes: "Accepted by email provider; delivery to inbox is not confirmed",
              recorded_by: schedule.created_by
            )
            InvoiceEvent.record!(invoice: invoice, event_type: "delivery_recorded", actor: schedule.created_by,
                                 occurred_at: sent_at, metadata: { delivery_id: delivery.id, send_schedule_id: schedule.id,
                                                                   recipient: recipient, provider_reference: reference })
          end
          # The provider has accepted the email. Record it without
          # revalidating the whole invoice, so an unrelated validation can't
          # roll back the delivery record.
          invoice.update_columns(sent_at: sent_at, updated_at: Time.current) if invoice.sent_at.blank?
          schedule.update!(status: "sent", sent_at: sent_at, provider_reference: reference, last_error: nil)
        end
      rescue StandardError => e
        # A provider response may have been lost. Keep the same idempotency key
        # for an explicit retry after the operator checks provider delivery.
        # A failed claim leaves unsaved changes on the record, and locking a
        # changed record raises, which would hide this error; drop them first.
        # A claim that failed is marked failed too, so it isn't retried forever.
        schedule.restore_attributes
        schedule.with_lock do
          if schedule.status == "sending" || (!claimed && schedule.status.in?(%w[pending queued]))
            schedule.update_columns(status: "failed", last_error: "#{e.class}: #{e.message}".truncate(500), updated_at: Time.current)
          end
        end
        raise
      end
    end
  end
end
