# frozen_string_literal: true

module Api
  module V1
    module Admin
      # Deliberately independent of the current company header, including a
      # stale/expired selected company. Each row is scoped again by the query.
      class ClientInboxController < ApplicationController
        include Auditable
        before_action :require_inbox_access!

        def index
          render json: query.page
        rescue ArgumentError => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def counts
          render json: { data: query.summary }
        rescue ArgumentError => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        private

        def query
          ClientInboxQuery.new(user: current_user, params: params.permit(:company_id, :kind, :status, :cursor, :per_page))
        end

        def require_inbox_access!
          return render(json: { error: "Staff access required" }, status: :forbidden) unless current_user&.payroll_access_allowed? && StaffRolePolicy.allowed?(current_user, :staff_workspace)

          organization_id = request.headers["X-Organization-Id"]
          if organization_id.present? && organization_id != current_user.organization_id.to_s
            render json: { error: "You do not have access to this organization" }, status: :forbidden
          end
        end
      end
    end
  end
end
