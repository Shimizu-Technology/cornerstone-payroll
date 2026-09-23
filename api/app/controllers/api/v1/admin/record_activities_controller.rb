# frozen_string_literal: true

module Api
  module V1
    module Admin
      class RecordActivitiesController < BaseController
        DEFAULT_PER_PAGE = 25
        MAX_PER_PAGE = 100

        def index
          scope = RecordActivityQuery.new(
            record_type: params[:record_type],
            record_id: params[:record_id],
            company_id: current_company_id
          ).call
          page = [ params.fetch(:page, 1).to_i, 1 ].max
          per_page = params.fetch(:per_page, DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
          total = scope.count
          logs = scope
                       .newest_first
                       .includes(:user, :company, :organization)
                       .offset((page - 1) * per_page)
                       .limit(per_page)

          render json: {
            data: logs.map { |log| AuditLogSerializer.call(log) },
            meta: {
              current_page: page,
              per_page: per_page,
              total_count: total,
              total_pages: (total.to_f / per_page).ceil
            }
          }
        rescue RecordActivityQuery::RecordNotFoundError
          render json: { error: "Record not found" }, status: :not_found
        end
      end
    end
  end
end
