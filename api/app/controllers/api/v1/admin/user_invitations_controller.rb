# frozen_string_literal: true

module Api
  module V1
    module Admin
      class UserInvitationsController < BaseController
        def create
          render json: { error: "Create the user in Settings → Users to send a Clerk invitation." }, status: :gone
        end
      end
    end
  end
end
