# frozen_string_literal: true

module Api
  module V1
    module Integrations
      module Aire
        # Server-to-server: an AIRE owner or admin asks Cornerstone to lock now,
        # move, or reset one published period's lock time. AIRE authenticates the
        # person; the period's own source credential authenticates AIRE. The
        # change is recorded here and republished to AIRE like any revision.
        class CutoffChangesController < ActionController::API
          include ConnectedPayrollControl
          before_action :require_connected_payroll!
          wrap_parameters false

          SCHEMA_VERSION = "1.0"
          UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
          ACTOR_FIELDS = %w[system user_id name email role payroll_user_id].freeze

          rescue_from ActionDispatch::Http::Parameters::ParseError, JSON::ParserError do
            render json: { error: "Request body must be valid JSON" }, status: :bad_request
          end

          def create
            calendar_period = authenticate_period!
            return unless calendar_period

            body = request.request_parameters
            return invalid("Unsupported lock-time request version") unless body["schema_version"] == SCHEMA_VERSION
            request_id = request.headers["Idempotency-Key"].to_s
            return invalid("Idempotency-Key must be a UUID") unless request_id.match?(UUID_FORMAT)
            return invalid("actor is required") unless body["actor"].is_a?(Hash)

            result = AirePayrollCalendar::CutoffChange.new(
              pay_period: calendar_period.pay_period,
              action: body["action"],
              cutoff_at: body["cutoff_at"],
              reason: body["reason"],
              source_actor: actor_from(body["actor"]),
              source: calendar_period.time_tracking_source,
              request_id: request_id
            ).call
            render json: { cutoff_change: serialize(result) }, status: result.idempotent ? :ok : :created
          rescue AirePayrollCalendar::CutoffChange::Error => e
            render json: { error: e.message }, status: e.status
          end

          private

          # Same model as the finalization receiver: find the period, then compare
          # the presented secret with its source's secret in constant time.
          def authenticate_period!
            external_id = params[:external_pay_period_id].to_s.downcase
            calendar_period = AirePayrollCalendarPeriod.includes(:time_tracking_source, :pay_period)
              .find_by(external_pay_period_id: external_id) if external_id.match?(UUID_FORMAT)
            source = calendar_period&.time_tracking_source
            secret = (request.headers["X-Shared-Secret"].presence || request.headers["X-Payroll-Shared-Secret"]).to_s
            expected = source&.shared_secret.to_s
            authenticated = source&.active? && expected.present? && secret.present? && expected.bytesize == secret.bytesize &&
                            ActiveSupport::SecurityUtils.secure_compare(expected, secret)
            return calendar_period if authenticated

            render json: { error: "Invalid AIRE integration credentials" }, status: :unauthorized
            nil
          end

          def actor_from(raw)
            raw.slice(*ACTOR_FIELDS).transform_values { |value| value.is_a?(Integer) ? value : value.to_s.strip.first(200) }
          end

          def invalid(message)
            render json: { error: message }, status: :unprocessable_entity
          end

          def serialize(result)
            override = result.override
            publication = result.publication
            {
              override_id: override.override_id,
              action: override.action,
              cutoff_at: override.cutoff_at.in_time_zone(AirePayrollCalendar::Contract::TIME_ZONE).iso8601,
              previous_cutoff_at: override.previous_cutoff_at.in_time_zone(AirePayrollCalendar::Contract::TIME_ZONE).iso8601,
              policy_cutoff_at: override.policy_cutoff_at.in_time_zone(AirePayrollCalendar::Contract::TIME_ZONE).iso8601,
              cutoff_source: override.reset? ? "policy" : "override",
              reason: override.reason,
              set_at: override.created_at.in_time_zone(AirePayrollCalendar::Contract::TIME_ZONE).iso8601,
              idempotent: result.idempotent,
              publication: publication && {
                schedule_version: publication.schedule_version,
                publication_id: publication.publication_id,
                delivery_status: publication.delivery_status
              }
            }
          end
        end
      end
    end
  end
end
