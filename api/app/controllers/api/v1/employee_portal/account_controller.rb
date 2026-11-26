# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      # Account-level employee routes that come before a link session, so they
      # can't require X-Employee-Link-Id: the signed-in user's links, and
      # claiming an invite with an existing login. Same Clerk checks as
      # BaseController, client-subdomain tokens allowed, 404 on every failure.
      # On a client subdomain both see only that subdomain's company.
      class AccountController < BaseController
        include RecentVerification
        include EmployeeLinkCheckParams

        skip_before_action :require_employee_link!
        before_action :reject_query_credentials!, only: :claim
        before_action :require_recent_verification!, only: :claim

        CLAIM_FAILED = "We couldn't add that employee access. Check the details and try again, or ask your manager for a new invite."

        # GET /api/v1/employee/links
        def links
          links = EmployeeLinks.openable_links(@current_user, azp: azp, origin: request_origin)
          response.headers["Cache-Control"] = "no-store"
          render json: { links: links.map { |link| link_payload(link) } }
        end

        # POST /api/v1/employee/links/claim
        def claim
          return render_write_maintenance if WriteMaintenance.enabled?

          terms_version = require_current_employee_terms
          return unless terms_version

          link_check_started!
          claim = EmployeeLinks::Claim.new(user: @current_user, **link_check_params, azp: azp, request: request, terms_version: terms_version)
          link = claim.call
          response.headers["Cache-Control"] = "no-store"
          return render_email_mismatch if !link && claim.refusal == :email_mismatch
          unless link
            wait_for_response_floor
            return render json: { error: CLAIM_FAILED, code: "claim_failed" }, status: :not_found
          end

          render json: { link: link_payload(link) }, status: :created
        end

        private

        # A user's links span companies, and a claim finds its link by token.
        def rls_system_reason
          "Resolve employee links for verified Clerk user"
        end

        def current_company_id
          nil
        end

        def azp
          @clerk_token_payload&.fetch("azp", nil)
        end

        def link_payload(link)
          {
            id: link.id,
            company_name: link.company.name,
            subdomain_slug: link.company.subdomain_slug,
            status: link.status,
            former_access_until: link.former_access_until&.iso8601,
            latest_pay_date: latest_pay_date_for(link)&.iso8601
          }
        end

        def latest_pay_date_for(link)
          return unless CompanyFeatures.for(link.company).employee_portal_feature?(:stubs)

          EmployeeStatements.new(context: link).latest_pay_date
        end

        def render_email_mismatch
          render json: { error: EmployeeLinks::EMAIL_MISMATCH, code: "email_mismatch" }, status: :forbidden
        end

        def render_write_maintenance
          response.headers["Retry-After"] = WriteMaintenance::RETRY_AFTER.to_s
          response.headers["Cache-Control"] = "no-store"
          render json: WriteMaintenance.payload, status: :service_unavailable
        end
      end
    end
  end
end
