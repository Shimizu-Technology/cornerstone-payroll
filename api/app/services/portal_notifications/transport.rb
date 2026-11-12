# frozen_string_literal: true

require "json"
require "securerandom"

module PortalNotifications
  # Sends through the contained Resend transport. Outside production,
  # PORTAL_EMAIL_TRANSPORT=capture records payloads locally instead of sending.
  module Transport
    class << self
      def capture?
        ENV["PORTAL_EMAIL_TRANSPORT"] == "capture" && !Rails.env.production?
      end

      def configured?
        return true if capture?

        from_email.present? && (StagingOutboundPolicy.staging? || ENV["RESEND_API_KEY"].present?)
      end

      def from_email
        ENV["RESEND_FROM_EMAIL"].presence || ENV["MAILER_FROM_EMAIL"].presence
      end

      def deliver(payload, idempotency_key:)
        return capture!(payload, idempotency_key) if capture?

        StagingMailTransport.deliver(payload, options: { idempotency_key: idempotency_key })
      end

      def captured
        @captured ||= []
      end

      def clear_captured!
        @captured = []
      end

      private

      def capture!(payload, idempotency_key)
        entry = payload.merge(idempotency_key: idempotency_key)
        captured << entry
        path = ENV["PORTAL_EMAIL_CAPTURE_PATH"].presence
        File.open(path, "a") { |file| file.puts(JSON.generate(entry)) } if path
        { "id" => "captured-#{SecureRandom.hex(6)}", "captured" => true }
      end
    end
  end
end
