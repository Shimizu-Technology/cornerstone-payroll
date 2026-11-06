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
            organization_id: current_user.organization_id,
            organization_name: current_user.organization&.name,
            company_id: current_company_id,
            company_name: current_company&.name,
            home_company_id: current_user.company_id,
            assigned_company_ids: current_user.accessible_company_ids,
            capabilities: StaffRolePolicy.capabilities_for(current_user),
            company_capabilities: Company.where(id: current_user.accessible_company_ids).order(:id).to_h do |company|
              [ company.id.to_s, StaffRolePolicy.capabilities_for(current_user, company: company) ]
            end
          }
        }
      end
    end
  end
end
