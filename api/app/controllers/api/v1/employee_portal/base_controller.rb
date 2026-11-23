# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      class BaseController < ActionController::API
        include MfaEnforceable

        before_action :authenticate_employee_user!, :enforce_mfa!, :require_employee_link!

        private

        def authenticate_employee_user!
          link_id = request.headers["X-Employee-Link-Id"]
          token = request.headers["Authorization"].to_s[/\ABearer (\S+)\z/, 1]
          unless token && link_id&.match?(/\A[1-9]\d{0,18}\z/) && link_id.to_i <= 2**63 - 1
            return head :not_found
          end

          @clerk_token_payload = ClerkTokenVerifier.new.verify(token)
          subject = @clerk_token_payload&.fetch("sub", nil)
          return head :not_found unless subject.is_a?(String) && subject.present? && !subject.start_with?("pending_")

          user = User.find_by(clerk_id: subject)
          return head :not_found unless user && StagingOutboundPolicy.tester?(user_id: user.id, email: user.email, id: subject)
          return head :not_found unless user.payroll_access_allowed?

          @current_user = user
        end

        def require_employee_link!
          @employee_link = @current_user.employee_account_links.portal_eligible.find_by(id: request.headers["X-Employee-Link-Id"])
          return head :not_found unless @employee_link&.portal_enabled?

          azp = @clerk_token_payload["azp"]
          if TenantSubdomainRegistry.client_origin?(azp) &&
              TenantSubdomainRegistry.enabled_origin_company_id(azp) != @employee_link.company_id
            head :not_found
          end
        end
      end
    end
  end
end
