# frozen_string_literal: true

module Api
  module V1
    module Integrations
      # Resend's webhook for email delivery events (M4-5): records delivered,
      # delayed, bounced and complained on the employee document notice that
      # sent the message. Signed by Resend through Svix and checked against
      # RESEND_WEBHOOK_SECRET; without that secret the endpoint is a 404 and
      # every notice's delivery stays "unknown".
      #
      # Every verified event is stored (once per Svix event id) before the
      # 2xx, so an event that arrives before its notice records the provider
      # id is applied later instead of lost.
      #
      # The body carries recipient addresses (data.to, data.from, ...), so
      # nothing from it is logged: request parameters are masked whole for
      # this endpoint before Rails' request instrumentation reads them, and
      # the body is read raw rather than through params.
      class EmailEventsController < ActionController::API
        MAX_BODY = 64.kilobytes
        EVENT_STATUSES = {
          "email.delivered" => "delivered",
          "email.delivery_delayed" => "delayed",
          "email.bounced" => "bounced",
          "email.failed" => "bounced",
          "email.suppressed" => "bounced",
          "email.complained" => "complained"
        }.freeze
        # Masks every parameter key, so the log line shows no value at all.
        MASK_ALL_PARAMETERS = [ /./ ].freeze

        wrap_parameters false

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
          bounce = data["bounce"].is_a?(Hash) ? data["bounce"] : {}
          EmployeeDocuments::NoticeDeliveryEvent.record!(event_id: request.headers["svix-id"], event_type: event["type"],
            message_id: data["email_id"], status: EVENT_STATUSES[event["type"]], bounce_type: bounce["type"],
            occurred_at: event["created_at"])
          head :no_content
        rescue JSON::ParserError
          head :bad_request
        end

        private

        # Runs before ActionController::Instrumentation builds the
        # start_processing payload (the "Parameters:" log line).
        def process_action(*)
          request.set_header("action_dispatch.parameter_filter", MASK_ALL_PARAMETERS)
          super
        end
      end
    end
  end
end
