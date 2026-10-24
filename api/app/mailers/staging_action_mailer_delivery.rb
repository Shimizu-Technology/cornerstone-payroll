# frozen_string_literal: true

class StagingActionMailerDelivery
  def initialize(_settings = {}); end

  def deliver!(message)
    StagingMailTransport.deliver({
      from: Array(message.from).first,
      to: message.to,
      cc: message.cc,
      bcc: message.bcc,
      reply_to: message.reply_to,
      subject: message.subject,
      html: message.html_part&.decoded,
      text: message.text_part&.decoded || (message.multipart? ? nil : message.body.decoded)
    }.compact)
  end
end
