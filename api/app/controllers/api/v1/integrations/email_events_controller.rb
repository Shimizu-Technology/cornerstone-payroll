# frozen_string_literal: true

module Api
  module V1
    module Integrations
      # Resend's webhook for email delivery events (M4-5): records delivered,
      # delayed, bounced and complained on the employee document notice that
      # sent the message. Signed by Resend through Svix and checked against
      # RESEND_WEBHOOK_SECRET; without that secret the endpoint is a 404 and
      # every notice's delivery stays "unknown".
      class EmailEventsController < ActionController::API
        MAX_BODY = 64.kilobytes
        EVENT_STATUSES = {
          "email.delivered" => "delivered",
          "email.delivery_delayed" => "delayed",
          "email.bounced" => "bounced",
          "email.complained" => "complained"
        }.freeze

        # POST /api/v1/integrations/email_events
        def create
          secret = ENV["RESEND_WEBHOOK_SECRET"].presence
          return head :not_found unless secret

          body = request.raw_post.to_s
          return head :payload_too_large if body.bytesize > MAX_BODY

          valid = ResendWebhookSignature.valid?(
            secret: secret, id: request.headers["svix-id"], timestamp: request.headers["svix-timestamp"],
            signatures: request.headers["svix-signature"], body: body
          )
          return head :unauthorized unless valid

          event = JSON.parse(body)
          return head :bad_request unless event.is_a?(Hash)

          data = event["data"].is_a?(Hash) ? event["data"] : {}
          status = EVENT_STATUSES[event["type"]]
          if status
            bounce = data["bounce"].is_a?(Hash) ? data["bounce"] : {}
            EmployeeDocuments::NoticeDeliveryEvent.record!(message_id: data["email_id"], status: status,
              bounce_type: bounce["type"], occurred_at: event["created_at"])
          end
          head :no_content
        rescue JSON::ParserError
          head :bad_request
        end
      end
    end
  end
end
