# frozen_string_literal: true

module Api
  module V1
    class AuthController < ApplicationController
      include CompanyRlsScoped
      # GET /api/v1/auth/me
      # Returns the current authenticated user
      def me
        unless current_user
          return render json: { error: "Not authenticated" }, status: :unauthorized
        end

        payload = {
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
          },
          roles: {
            staff: StaffRolePolicy.allowed?(current_user, :staff_workspace),
            client: current_user.client?,
            employee_links_count: current_user.employee_account_links.portal_eligible.includes(company: :organization).count(&:portal_enabled?)
          },
          features: current_company ? CompanyFeatures.for(current_company).summary : nil
        }
        if @clerk_token_payload && MfaPolicy.enabled?
          payload[:mfa_required] = MfaPolicy.required_for?(user: current_user)
          payload[:mfa_verified] = MfaPolicy.verified_second_factor?(@clerk_token_payload)
        end
        render json: payload
      end

      private

      def rls_system_reason
        "Resolve linked employee accounts for authenticated user"
      end

      def render_mfa_required
        return super unless action_name == "me" && (request.get? || request.head?)

        render json: { mfa_required: true, mfa_verified: false }
      end

      def allow_client_subdomain_token?
        action_name == "me"
      end
    end
  end
end
