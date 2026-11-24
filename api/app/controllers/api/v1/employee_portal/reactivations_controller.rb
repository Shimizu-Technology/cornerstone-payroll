# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      # POST /api/v1/employee/links/reactivate: a rehired employee-only person
      # whose login was deactivated when their last link closed. It is the only
      # route that accepts a deactivated login, and only that kind: an active
      # login uses links/claim. It needs a fresh sign-in (step-up) plus the
      # invite check; 404 on every failure.
      class ReactivationsController < BaseController
        include RecentVerification

        skip_before_action :require_employee_link!
        before_action :require_recent_verification!

        def create
          response.headers["Cache-Control"] = "no-store"
          return render_write_maintenance if WriteMaintenance.enabled?

          link = EmployeeLinks::Reactivate.call(
            user: @current_user, token: params[:token], code: params[:code],
            date_of_birth: params[:date_of_birth], ssn_last4: params[:ssn_last4],
            azp: @clerk_token_payload&.fetch("azp", nil), request: request
          )
          return render json: { error: AccountController::CLAIM_FAILED, code: "claim_failed" }, status: :not_found unless link

          render json: { link: { id: link.id, company_name: link.company.name, subdomain_slug: link.company.subdomain_slug,
            status: link.status, former_access_until: nil } }, status: :created
        end

        private

        def allow_deactivated_employee_login?
          true
        end

        def rls_system_reason
          "Reactivate a rehired employee login against its new link"
        end

        def current_company_id
          nil
        end

        def render_write_maintenance
          response.headers["Retry-After"] = WriteMaintenance::RETRY_AFTER.to_s
          render json: WriteMaintenance.payload, status: :service_unavailable
        end
      end
    end
  end
end
