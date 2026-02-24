# frozen_string_literal: true

module Api
  module V1
    class AuthController < ApplicationController
      # GET /api/v1/auth/me
      # Returns the current authenticated user
      def me
        render json: {
          user: {
            id: current_user.id,
            email: current_user.email,
            name: current_user.name,
            role: current_user.role,
            company_id: current_user.company_id,
            company_name: current_user.company&.name
          }
        }
      end
    end
  end
end
