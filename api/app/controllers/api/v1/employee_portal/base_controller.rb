# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      class BaseController < ActionController::API
        include MfaEnforceable
        include EmployeePortalRequestContext

        before_action :authenticate_employee_user!, :enforce_mfa!, :require_employee_link!
        include CompanyRlsScoped
        # After the RLS scope, so audit rows are written inside the link's company.
        include Auditable

        private

        def rls_company_id
          @employee_link&.company_id
        end

        def current_company_id
          @employee_link&.company_id
        end

        # Every successful employee view and download is audited, not only writes.
        def audit_worthy_request?
          true
        end

        def authenticate_employee_user!
          user = verified_employee_portal_user
          if employee_session_fenced?
            return render json: EmployeeLinks::SessionFence::SIGN_IN_AGAIN, status: :unauthorized
          end
          return head :not_found unless user

          @current_user = user
          set_current_employee_user(user)
        end

        def require_employee_link!
          link_id = request.headers["X-Employee-Link-Id"]
          unless link_id&.match?(/\A[1-9]\d{0,18}\z/) && link_id.to_i <= 2**63 - 1
            return head :not_found
          end

          azp = @clerk_token_payload["azp"]
          @employee_link = TenantScope.as_system(reason: "Resolve employee link for verified Clerk user") do
            link = @current_user.employee_account_links.portal_eligible.find_by(id: link_id)
            link if link && EmployeeLinks.openable?(@current_user, link, azp: azp)
          end
          return head :not_found unless @employee_link

          Current.company_id = @employee_link.company_id
        end
      end
    end
  end
end
