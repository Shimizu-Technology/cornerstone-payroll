# frozen_string_literal: true

class StagingMailTransport
  SUPPRESSED = { "id" => nil, "suppressed" => true }.freeze

  # Whether mail can leave this process: staging's contained Resend, a local
  # copy's capture files, or a configured Resend key.
  def self.available?
    StagingOutboundPolicy.staging? || LocalDeployment.local? || ENV["RESEND_API_KEY"].present?
  end

  def self.deliver(payload = nil, options: {}, **attributes)
    payload ||= attributes
    # Inside DemoOutbound.scoped, only allow-listed recipients remain.
    payload = DemoOutbound.filter_payload(payload)
    return SUPPRESSED.dup if payload.nil?
    return LocalDeployment.capture_mail!(payload, options: options) if LocalDeployment.local?

    filtered = StagingOutboundPolicy.mail_payload(payload)
    if StagingOutboundPolicy.staging? && filtered.nil?
      Rails.logger.info("[STAGING] captured email; recipient/body/subject/attachments redacted")
      return { "id" => "staging-captured", "staging_captured" => true, "staging_recipients" => [] }
    end

    previous = Thread.current[:staging_mail_transport]
    Thread.current[:staging_mail_transport] = true
    response = options.empty? ? Resend::Emails.send(filtered) : Resend::Emails.send(filtered, options: options)
    return response unless StagingOutboundPolicy.staging?
    response.merge("staging_captured" => false, "staging_recipients" => Array(filtered[:to]))
  ensure
    Thread.current[:staging_mail_transport] = previous
  end
end
