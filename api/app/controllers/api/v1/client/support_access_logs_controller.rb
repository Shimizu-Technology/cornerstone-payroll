# frozen_string_literal: true

module Api
  module V1
    module Client
      class SupportAccessLogsController < BaseController
        def index
          response.headers["Cache-Control"] = "private, no-store"
          events = AuditLog.where(company_id: current_company_id, action: ViewAsGrant::STARTED_ACTION)
            .newest_first.limit(50)
          render json: { events: events.map do |event|
            {
              id: event.id.to_s, viewed_at: event.created_at.iso8601,
              description: AuditLogPresenter.new(event).headline
            }
          end }
        end
      end
    end
  end
end
