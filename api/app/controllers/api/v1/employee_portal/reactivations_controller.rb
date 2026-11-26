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
        include EmployeeLinkCheckParams

        skip_before_action :require_employee_link!
        before_action :reject_query_credentials!
        before_action :require_recent_verification!

        def create
          response.headers["Cache-Control"] = "no-store"
          return render_write_maintenance if WriteMaintenance.enabled?

          terms_version = require_current_employee_terms
          return unless terms_version

          link_check_started!
          reactivation = EmployeeLinks::Reactivate.new(
            user: @current_user, **link_check_params, azp: @clerk_token_payload&.fetch("azp", nil),
            session: @clerk_token_payload, request: request, terms_version: terms_version
          )
          link = reactivation.call
          if !link && reactivation.refusal
            return render json: AccountController.claim_refusal_json(reactivation.refusal), status: :forbidden
          end
          unless link
            wait_for_response_floor
            return render json: { error: AccountController::CLAIM_FAILED, code: "claim_failed" }, status: :not_found
          end

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
