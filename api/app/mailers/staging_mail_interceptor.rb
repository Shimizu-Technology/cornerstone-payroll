# frozen_string_literal: true

class StagingMailInterceptor
  def self.delivering_email(message)
    return unless StagingOutboundPolicy.staging?
    message.delivery_method(StagingActionMailerDelivery)
    payload = StagingOutboundPolicy.mail_payload({ to: message.to, cc: message.cc, bcc: message.bcc, reply_to: message.reply_to, subject: message.subject })
    if payload.nil?
      message.perform_deliveries = false
      # Clear the entire header and MIME tree before deliver.action_mailer
      # encodes the message (including custom headers and attachment metadata).
      message.header = ""
      message.parts.clear
      message.body = "[STAGING] captured email; content redacted"
      message.subject = "[STAGING] captured email; content redacted"
      Rails.logger.info("[STAGING] captured Action Mailer email; content redacted")
      return
    end
    %i[to cc bcc reply_to subject].each { |field| message.public_send("#{field}=", payload[field]) }
    message.attachments.to_a.each { |attachment| message.parts.delete(attachment) }
  end
end
