# frozen_string_literal: true

module Api
  module V1
    class AuthController < ApplicationController
      # GET /api/v1/auth/me
      # Returns the current authenticated user
      def me
        unless current_user
          return render json: { error: "Not authenticated" }, status: :unauthorized
        end

        render json: {
          user: {
            id: current_user.id,
            email: current_user.email,
            name: current_user.name,
            role: current_user.role,
            company_id: current_company_id,
            company_name: current_company&.name,
            home_company_id: current_user.company_id,
            super_admin: current_user.super_admin?,
            assigned_company_ids: current_user.accessible_company_ids
          }
        }
      end
    end
  end
end
