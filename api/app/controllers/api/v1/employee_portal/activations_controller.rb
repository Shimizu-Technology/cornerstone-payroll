# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      # POST /api/v1/employee/activation: sign-up for a person with no Payroll
      # login, reachable before any session exists. The body carries a token
      # or a one-time code, date of birth, SSN last 4, and the email to sign
      # up with. Rate limited in config/initializers/rack_attack.rb.
      #
      # Starting an account and being sent to sign in get the same status and
      # the same fields. Telling them apart still needs a valid invite secret
      # plus DOB and SSN-4, under the lockout and per-invite limits; that
      # remaining "this address has a login" signal is an accepted residual
      # (M4-2 plan).
      class ActivationsController < ActionController::API
        include EmployeePortalRequestContext
        include EmployeeLinkCheckParams
        include CompanyRlsScoped

        before_action :reject_query_credentials!

        FAILED = "We couldn't verify those details. Check them and try again, or ask your manager for a new invite."
        SIGN_IN = "We couldn't start a new account with that email. If you already have an account, sign in and " \
          "choose \"Add employee access\". Otherwise, try a different email."
        UNAVAILABLE = "Sign-up isn't available right now. Try again later."

        def create
          response.headers["Cache-Control"] = "no-store"
          return render_unavailable if WriteMaintenance.enabled?

          link_check_started!
          result = EmployeeLinks::Activate.call(
            **link_check_params, email: link_body_param(:email), use_for_notices: link_body_param(:use_for_notices),
            request: request
          )
          wait_for_response_floor unless result.outcome == :sign_up
          case result.outcome
          when :sign_up then render json: { next: "sign_up", sign_up_url: result.url, message: nil }
          when :sign_in then render json: { next: "sign_in", sign_up_url: nil, message: SIGN_IN }
          when :unavailable then render_unavailable
          else render json: { error: FAILED, code: "activation_failed" }, status: :unprocessable_content
          end
        end

        private

        def rls_system_reason
          "Check employee app sign-up before any session exists"
        end

        def render_unavailable
          render json: { error: UNAVAILABLE, code: "activation_unavailable" }, status: :service_unavailable
        end
      end
    end
  end
end
