# frozen_string_literal: true

module Api
  module V1
    module Integrations
      module Aire
        class EventsController < ActionController::API
          wrap_parameters false

          rescue_from ActionController::ParameterMissing,
                      ActionDispatch::Http::Parameters::ParseError,
                      JSON::ParserError,
                      with: :invalid_request

          def create
            result = AirePayrollEvents::Receiver.new(
              payload: request.request_parameters,
              shared_secret: request.headers["X-Shared-Secret"].presence || request.headers["X-Payroll-Shared-Secret"],
              idempotency_key: request.headers["Idempotency-Key"]
            ).call
            render json: {
              event_id: result.event.event_id,
              status: result.event.verification_status,
              idempotent: !result.created
            }, status: :accepted
          rescue AirePayrollEvents::Receiver::UnauthorizedError => e
            render json: { error: e.message }, status: :unauthorized
          rescue AirePayrollEvents::Receiver::ConflictError => e
            render json: { error: e.message }, status: :conflict
          rescue AirePayrollEvents::Receiver::Error, ActiveRecord::RecordInvalid => e
            message = e.respond_to?(:record) ? e.record.errors.full_messages.join(", ") : e.message
            render json: { error: message }, status: :unprocessable_entity
          end

          private

          def invalid_request
            render json: { error: "Request body must be valid JSON" }, status: :bad_request
          end
        end
      end
    end
  end
end
