# frozen_string_literal: true

module Api
  module V1
    module Admin
      # M4-9d: the selected company's employee app switch, its readiness
      # checklist, the organization's demo early-access window and the demo
      # kill switch. Org admins only (manage_employee_app_switch); setting or
      # extending early access is for a super_admin (the owner) only.
      # Turning anything on, or setting early access, needs a fresh step-up
      # (MfaPolicy: a second factor with REQUIRE_MFA on, a first factor while
      # it's off); turning off, ending early access and the kill switch never do.
      class EmployeeAppSwitchesController < BaseController
        include RecentVerification

        before_action :no_store
        before_action :require_selected_company!
        before_action :require_switch_access!

        def show
          render json: { data: payload(EmployeeAppSwitch::Readiness.new(company: current_company)) }
        end

        def update
          skip_default_audit_log!
          update = EmployeeAppSwitch::Update.new(company: current_company, actor: current_user,
            changes: params[:changes].try(:to_unsafe_h), reason: params[:reason], session_claims: @clerk_token_payload)
          # Failing checks are listed before a fresh step-up is asked for.
          update.preflight! if update.turning_on?
          result = update.call
          render json: { data: payload(EmployeeAppSwitch::Readiness.new(company: current_company)), saved: result.except(:values) }
        rescue EmployeeAppSwitch::StepUpRequired => error
          # The service refused; the concern renders Clerk's step-up prompt.
          require_recent_verification!
          render json: { error: error.message }, status: :forbidden unless performed?
        rescue EmployeeAppSwitch::NotReady => error
          render json: { error: "Not ready to turn on yet. Fix the failing checks first.", code: "not_ready",
                         failing_checks: error.failures.map(&:as_json) }, status: :unprocessable_entity
        rescue EmployeeAppSwitch::Forbidden => error
          render json: { error: error.message }, status: :forbidden
        rescue EmployeeAppSwitch::Invalid, ActiveRecord::RecordInvalid => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def set_early_access
          skip_default_audit_log!
          return unless verified_for_early_access!

          EmployeeAppSwitch::EarlyAccess.set!(organization: current_company.organization, actor: current_user,
            expires_on: params[:expires_on], company_ids: params[:company_ids], reason: params[:reason])
          render json: { data: payload(EmployeeAppSwitch::Readiness.new(company: current_company)) }
        rescue EmployeeAppSwitch::Forbidden => error
          render json: { error: error.message }, status: :forbidden
        rescue EmployeeAppSwitch::Invalid, ActiveRecord::RecordInvalid => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def end_early_access
          skip_default_audit_log!
          EmployeeAppSwitch::EarlyAccess.end!(organization: current_company.organization, actor: current_user, reason: params[:reason])
          render json: { data: payload(EmployeeAppSwitch::Readiness.new(company: current_company)) }
        rescue EmployeeAppSwitch::Forbidden => error
          render json: { error: error.message }, status: :forbidden
        rescue EmployeeAppSwitch::Invalid => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def demo_stop
          skip_default_audit_log!
          result = EmployeeAppSwitch::DemoStop.call(organization: current_company.organization, actor: current_user,
            reason: params[:reason])
          render json: { data: payload(EmployeeAppSwitch::Readiness.new(company: current_company)), stopped: result }
        rescue EmployeeAppSwitch::Forbidden => error
          render json: { error: error.message }, status: :forbidden
        rescue EmployeeAppSwitch::Invalid => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        private

        # Early access and the kill switch span the organization's demo
        # companies, so they run outside a single company's scope.
        def rls_system_reason
          return "Change demo employee app early access" if action_name.in?(%w[set_early_access end_early_access demo_stop])

          super
        end

        def no_store
          response.headers["Cache-Control"] = "private, no-store"
        end

        def require_selected_company!
          return if current_company

          render json: { error: "Select a client first." }, status: :unprocessable_entity
        end

        def require_switch_access!
          return if EmployeeAppSwitch.allowed?(current_user, current_company)

          render json: { error: StaffRolePolicy.error_message(:manage_employee_app_switch) }, status: :forbidden
        end

        def verified_for_early_access!
          require_recent_verification!
          !performed?
        end

        def payload(readiness)
          company = current_company
          stored = EmployeeAppSwitch.switched_on_values(company)
          effective = EmployeeAppSwitch.effective_values(company)
          failures = readiness.as_json
          {
            company: { id: company.id, name: company.name, demo: company.demo?, live: company.live_payroll?,
                       subdomain_slug: company.subdomain_slug },
            switches: EmployeeAppSwitch::SWITCHES.map do |key, meta|
              { key: key, label: meta[:label], description: meta[:description], on: stored.fetch(key),
                open_today: effective.fetch(key), feature: EmployeeAppSwitch::FEATURES.include?(key),
                blocked_by: failures.dig(:switch_checks, key) }
            end,
            stays_off: EmployeeAppSwitch::STAYS_OFF.map { |key, meta| { key: key, label: meta[:label], description: meta[:description] } },
            readiness: failures,
            early_access: early_access_payload(company)
          }
        end

        def early_access_payload(company)
          organization_id = company.organization_id
          demos = Company.demo.active.where(organization_id: organization_id).order(:name, :id).map { |demo| { id: demo.id, name: demo.name } }
          windows = EmployeeAppEarlyAccessWindow.where(organization_id: organization_id).history_order.limit(5).to_a
          names = Company.where(id: windows.flat_map(&:company_ids)).pluck(:id, :name).to_h
          people = User.where(id: windows.flat_map { |window| [ window.set_by_id, window.ended_by_id ] }.compact).pluck(:id, :name).to_h
          {
            name: EmployeeAppEarlyAccessWindow::NAME,
            can_set: current_user.super_admin?,
            max_days: EmployeeAppEarlyAccessWindow::MAX_DAYS,
            max_companies: EmployeeAppEarlyAccessWindow::MAX_COMPANIES,
            demo_companies: demos,
            windows: windows.map do |window|
              {
                id: window.id, status: window.status, expires_on: window.expires_on.iso8601,
                companies: window.company_ids.map { |id| { id: id, name: names[id] } },
                reason: window.reason, set_by: people[window.set_by_id], approved_by: people[window.set_by_id],
                set_at: window.created_at.utc.iso8601, retired_at: window.retired_at&.utc&.iso8601,
                ended_at: window.ended_at&.utc&.iso8601, ended_by: people[window.ended_by_id], end_reason: window.end_reason
              }
            end
          }
        end
      end
    end
  end
end
