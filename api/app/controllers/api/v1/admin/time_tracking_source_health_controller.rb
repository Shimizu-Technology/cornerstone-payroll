# frozen_string_literal: true

module Api
  module V1
    module Admin
      class TimeTrackingSourceHealthController < BaseController
        def show
          source = TimeTrackingSource.find_by!(id: params[:source_id], company_id: current_company_id)
          response.headers["Cache-Control"] = "no-store"
          response.headers["Pragma"] = "no-cache"
          render json: TimeTracking::ConnectorHealth.new(source).call
        end
      end
    end
  end
end
