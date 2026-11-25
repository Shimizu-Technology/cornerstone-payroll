# frozen_string_literal: true

module Api
  module V1
    module Client
      class PortalThreadsController < BaseController
        include ClientPortalThreadActions

        def update
          if params[:status].present? && !ClientPortalThread.staff_user?(current_user)
            return render json: { error: "Not authorized to change thread status" }, status: :forbidden
          end
          if params[:subject].present? && !ClientPortalThread.staff_user?(current_user) && @thread.created_by_id != current_user.id
            return render json: { error: "Not authorized to rename this thread" }, status: :forbidden
          end

          super
        end
      end
    end
  end
end
