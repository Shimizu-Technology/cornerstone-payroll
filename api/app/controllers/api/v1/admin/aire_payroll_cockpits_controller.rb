# frozen_string_literal: true

module Api
  module V1
    module Admin
      class AirePayrollCockpitsController < BaseController
        before_action :set_pay_period_and_source
        before_action :disable_http_caching

        def show
          presenter = cockpit_presenter
          period_payload = cockpit_client.payroll_cockpit_period(
            external_pay_period_id: external_pay_period_id
          )
          employees_payload = cockpit_client.payroll_cockpit_employees(
            page: bounded_page(:employee_page),
            per_page: bounded_per_page(:employee_per_page, maximum: 100),
            active: params[:active]
          )

          render json: {
            aire_payroll_cockpit: presenter.overview(
              period_payload: period_payload,
              employees_payload: employees_payload,
              command_access: command_access_payload
            )
          }
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        def time_entries
          payload = cockpit_client.payroll_cockpit_time_entries(
            external_pay_period_id: external_pay_period_id,
            page: bounded_page(:page),
            per_page: bounded_per_page(:per_page, maximum: 250),
            employee_id: params[:employee_id],
            approval_status: params[:approval_status]
          )
          render json: cockpit_presenter.time_entries(payload)
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        def exceptions
          payload = cockpit_client.payroll_cockpit_exceptions(
            external_pay_period_id: external_pay_period_id,
            page: bounded_page(:page),
            per_page: bounded_per_page(:per_page, maximum: 250),
            leave_page: bounded_page(:leave_page),
            leave_per_page: bounded_per_page(:leave_per_page, maximum: 100)
          )
          render json: cockpit_presenter.exceptions(payload)
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        def approve_time_entry
          decision = command_params.fetch(:decision).to_s.downcase
          unless %w[approve deny].include?(decision)
            return render json: { error: "Decision must be approve or deny" }, status: :unprocessable_entity
          end

          result = cockpit_client(with_delegation: true).approve_payroll_time_entry(
            entry_id: params[:time_entry_id],
            command_id: command_params.fetch(:command_id),
            expected_version: command_params.fetch(:expected_version),
            decision: decision,
            reason: command_params.fetch(:reason)
          )
          record_command_audit!(
            action: "aire_payroll_cockpit##{decision == 'deny' ? 'time_denied' : 'time_approved'}",
            record_type: "AireTimeEntry",
            record_id: params[:time_entry_id],
            command_id: command_params[:command_id],
            result: result
          )
          render json: result
        rescue ActionController::ParameterMissing => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        def finalize
          result = cockpit_client(with_delegation: true).finalize_payroll_cockpit_period(
            external_pay_period_id: external_pay_period_id,
            command_id: command_params.fetch(:command_id),
            expected_version: command_params.fetch(:expected_version),
            reason: command_params.fetch(:reason)
          )
          record_command_audit!(
            action: "aire_payroll_cockpit#finalization_requested",
            record_type: "PayPeriod",
            record_id: @pay_period.id,
            command_id: command_params[:command_id],
            result: result
          )
          render json: result, status: :accepted
        rescue ActionController::ParameterMissing => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        private

        def disable_http_caching
          response.headers["Cache-Control"] = "no-store"
          response.headers["Pragma"] = "no-cache"
        end

        def set_pay_period_and_source
          @pay_period = PayPeriod.find_by!(id: params[:pay_period_id], company_id: current_company_id)
          @source = @pay_period.aire_payroll_calendar_period&.time_tracking_source
        end

        def external_pay_period_id
          @pay_period.aire_payroll_calendar_period&.external_pay_period_id ||
            raise(
              TimeTracking::Client::Error.new(
                "Publish this pay period to AIRE before opening its payroll cockpit",
                response_status: 422
              )
            )
        end

        def cockpit_presenter
          @cockpit_presenter ||= AirePayrollCockpit::Presenter.new(source: @source)
        end

        def cockpit_client(with_delegation: false)
          delegation = current_delegation if with_delegation
          TimeTracking::Client.new(@source, delegation: delegation)
        end

        def command_access_payload
          delegation = current_delegation
          {
            can_read: true,
            can_command: StaffRolePolicy.allowed?(current_user, :manage_client_configuration) && delegation.present?,
            delegation_configured: delegation.present?
          }
        end

        def current_delegation
          @current_delegation ||= @source.delegation_for(current_user)
        end

        def command_params
          params.permit(:command_id, :expected_version, :decision, :reason)
        end

        def bounded_page(key)
          [ params[key].to_i, 1 ].max
        end

        def bounded_per_page(key, maximum:)
          requested = params[key].to_i
          requested = maximum if requested <= 0
          requested.clamp(1, maximum)
        end

        def record_command_audit!(action:, record_type:, record_id:, command_id:, result:)
          AuditLog.record!(
            user: current_user,
            company_id: current_company_id,
            action: action,
            record_type: record_type,
            record_id: record_id,
            subject_name: "AIRE payroll command",
            event_category: "payroll",
            metadata: {
              command_id: command_id,
              replayed: result.dig("command", "replayed") == true
            }
          )
        end

        def render_source_error(error)
          status = case error.response_status
          when 409 then :conflict
          when 422 then :unprocessable_entity
          when 401, 403 then :failed_dependency
          else :bad_gateway
          end
          render json: { error: error.message }, status: status
        end
      end
    end
  end
end
