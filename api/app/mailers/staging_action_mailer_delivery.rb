# frozen_string_literal: true

class StagingActionMailerDelivery
  attr_reader :settings

  def initialize(settings = {})
    @settings = settings
  end

  def deliver!(message)
    StagingMailTransport.deliver({
      from: Array(message.from).first,
      to: message.to,
      cc: message.cc,
      bcc: message.bcc,
      reply_to: message.reply_to,
      subject: message.subject,
      html: message.html_part&.decoded || (!message.multipart? && message.mime_type == "text/html" ? message.body.decoded : nil),
      text: message.text_part&.decoded || (!message.multipart? && message.mime_type != "text/html" ? message.body.decoded : nil)
    }.compact)
  end
end
