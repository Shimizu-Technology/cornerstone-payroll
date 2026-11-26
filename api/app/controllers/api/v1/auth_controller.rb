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

        company_ids = Current.view_as_grant ? [ current_company_id ] : current_user.accessible_company_ids
        home_company_id = if Current.view_as_grant
          current_company_id
        elsif current_user.client?
          company_ids.include?(current_user.company_id) ? current_user.company_id : nil
        else
          current_user.company_id
        end
        payload = {
          user: {
            id: current_user.id,
            email: current_user.email,
            name: current_user.name,
            role: current_user.role,
            client_access_level: (current_user.client_access_level if current_user.client?),
            organization_id: current_user.organization_id,
            organization_name: current_user.organization&.name,
            company_id: current_company_id,
            company_name: current_company&.name,
            home_company_id: home_company_id,
            assigned_company_ids: company_ids,
            capabilities: StaffRolePolicy.capabilities_for(current_user),
            company_capabilities: Company.where(id: company_ids).order(:id).to_h do |company|
              [ company.id.to_s, StaffRolePolicy.capabilities_for(current_user, company: company) ]
            end
          },
          roles: {
            staff: StaffRolePolicy.allowed?(current_user, :staff_workspace),
            client: current_user.client?,
            employee_links_count: Current.view_as_grant ? 0 : employee_links_count
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

      def employee_links_count
        EmployeeLinks.openable_links(current_user, azp: @clerk_token_payload&.fetch("azp", nil),
          origin: request.headers["Origin"]).size
      end

      def rls_system_reason
        "Resolve linked employee accounts for authenticated user"
      end

      # The bootstrap call answers 200 so the apps can show the recovery
      # screen, and carries the same code and message as every other MFA 403:
      # mfa_enrollment_required (set up a second factor) or mfa_required
      # (enrolled; sign in again and finish the second step).
      def render_mfa_required
        return super unless action_name == "me" && (request.get? || request.head?)

        render json: { mfa_required: true, mfa_verified: false }.merge(MfaPolicy.denial_body(@clerk_token_payload))
      end

      def allow_client_subdomain_token?
        action_name == "me"
      end
    end
  end
end
