# frozen_string_literal: true

module Api
  module V1
    module Admin
      class AirePayrollCockpitsController < BaseController
        before_action :set_pay_period_and_source
        before_action :disable_http_caching
        before_action :require_manual_reconciliation_access!, only: %i[create_manual_allocation retry_manual_allocation create_employee_mapping]

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
              command_access: command_access_payload,
              routing_options: routing_options_payload
            )
          }
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        def manual_review
          require_aire_source!
          payload = cockpit_client(with_delegation: true).payroll_cockpit_manual_review(
            start_date: @pay_period.start_date.iso8601,
            end_date: @pay_period.end_date.iso8601,
            external_pay_period_id: @pay_period.id
          )
          render json: cockpit_presenter.manual_review(payload).merge(
            "cornerstone_manual_allocations" => @pay_period.time_tracking_manual_allocations
              .includes(:employee, payroll_item: :check_events)
              .order(:id)
              .map { |allocation| manual_allocation_json(allocation) }
          )
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        def create_employee_mapping
          require_aire_source!
          mapping = TimeTracking::EmployeeMappingService.new(pay_period: @pay_period, source: @source).link!(
            source_user_id: params.require(:source_user_id), employee_id: params.require(:employee_id)
          )
          render json: { mapping: { source_user_id: mapping.source_user_id,
                                    source_user_uuid: mapping.source_user_uuid,
                                    employee_id: mapping.employee_id,
                                    employee_name: mapping.employee.full_name } }, status: :ok
        rescue ActionController::ParameterMissing, ArgumentError,
               TimeTracking::EmployeeMappingService::Error, TimeTrackingEmployeeMapping::IdentityConflict,
               ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        def create_manual_allocation
          allocation = manual_allocation_service.create!(**manual_allocation_params.to_h.symbolize_keys)
          render json: { manual_allocation: manual_allocation_json(allocation) }, status: :created
        rescue ActionController::ParameterMissing, ArgumentError,
               TimeTracking::ManualAllocationService::Error, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        def retry_manual_allocation
          allocation = @pay_period.time_tracking_manual_allocations.find(params[:manual_allocation_id])
          manual_allocation_service.sync!(allocation)
          render json: { manual_allocation: manual_allocation_json(allocation.reload) }
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

        def settlement_cases
          payload = cockpit_client.payroll_cockpit_settlement_cases(
            external_pay_period_id: external_pay_period_id,
            page: bounded_page(:page),
            per_page: bounded_per_page(:per_page, maximum: 250),
            status: params[:status]
          )
          render json: cockpit_presenter.settlement_cases(payload)
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
            reason: command_params[:reason],
            result: result
          )
          render json: result
        rescue ActionController::ParameterMissing => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        def approve_time_entry_overtime
          decision = command_params.fetch(:decision).to_s.downcase
          unless %w[approve deny].include?(decision)
            return render json: { error: "Decision must be approve or deny" }, status: :unprocessable_entity
          end

          result = cockpit_client(with_delegation: true).approve_payroll_overtime(
            entry_id: params[:time_entry_id],
            command_id: command_params.fetch(:command_id),
            expected_version: command_params.fetch(:expected_version),
            decision: decision,
            reason: command_params.fetch(:reason)
          )
          record_command_audit!(
            action: "aire_payroll_cockpit##{decision == 'deny' ? 'overtime_denied' : 'overtime_approved'}",
            record_type: "AireTimeEntry",
            record_id: params[:time_entry_id],
            command_id: command_params[:command_id],
            reason: command_params[:reason],
            result: result
          )
          render json: result
        rescue ActionController::ParameterMissing => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        def correct_time_entry
          attributes = correction_params.except(:command_id, :expected_version, :reason).to_h
          result = cockpit_client(with_delegation: true).correct_payroll_time_entry(
            entry_id: params[:time_entry_id],
            command_id: correction_params.fetch(:command_id),
            expected_version: correction_params.fetch(:expected_version),
            reason: correction_params.fetch(:reason),
            attributes: attributes
          )
          record_command_audit!(
            action: "aire_payroll_cockpit#time_corrected",
            record_type: "AireTimeEntry",
            record_id: params[:time_entry_id],
            command_id: correction_params[:command_id],
            reason: correction_params[:reason],
            result: result
          )
          render json: result
        rescue ActionController::ParameterMissing => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        def route_settlement_case
          destination_kind = route_params.fetch(:destination_kind).to_s
          unless %w[regular not_payable].include?(destination_kind)
            return render json: {
              error: "Choose the next regular payroll or mark the case not payable"
            }, status: :unprocessable_entity
          end

          target_period = if destination_kind == "regular"
            routing_options_payload.find do |option|
              option.fetch(:external_pay_period_id) == route_params[:target_external_pay_period_id]
            end
          end
          if destination_kind == "regular" && target_period.nil?
            return render json: {
              error: "Choose an available future regular payroll"
            }, status: :unprocessable_entity
          end

          result = cockpit_client(with_delegation: true).route_payroll_settlement_case(
            case_id: params[:settlement_case_id],
            command_id: route_params.fetch(:command_id),
            expected_version: route_params.fetch(:expected_version),
            reason: route_params.fetch(:reason),
            destination_kind: destination_kind,
            target_external_pay_period_id: target_period&.fetch(:external_pay_period_id, nil),
            action_due_on: target_period&.fetch(:pay_date, nil)
          )
          record_command_audit!(
            action: "aire_payroll_cockpit#settlement_case_routed",
            record_type: "AirePayrollSettlementCase",
            record_id: params[:settlement_case_id],
            command_id: route_params[:command_id],
            reason: route_params[:reason],
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
            reason: command_params[:reason],
            result: result
          )
          render json: result, status: :accepted
        rescue ActionController::ParameterMissing => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        private

        def require_manual_reconciliation_access!
          require_capability!(:manage_client_configuration)
        end

        def manual_allocation_params
          %i[payroll_item_id source_time_entry_id source_time_entry_version source_user_uuid
             regular_hours overtime_hours original_work_date note].each { |key| params.require(key) }
          params.permit(:payroll_item_id, :source_time_entry_id, :source_time_entry_version,
                        :source_user_uuid, :regular_hours, :overtime_hours,
                        :original_work_date, :note)
        end

        def manual_allocation_service
          @manual_allocation_service ||= TimeTracking::ManualAllocationService.new(
            pay_period: @pay_period, source: @source, actor: current_user
          )
        end

        def manual_allocation_json(allocation)
          {
            id: allocation.id,
            payroll_item_id: allocation.payroll_item_id,
            employee_id: allocation.employee_id,
            employee_name: allocation.employee.full_name,
            source_user_uuid: allocation.source_user_uuid,
            source_time_entry_id: allocation.source_time_entry_id,
            source_time_entry_version: allocation.source_time_entry_version,
            original_work_date: allocation.original_work_date.iso8601,
            regular_hours: allocation.regular_hours.to_f,
            overtime_hours: allocation.overtime_hours.to_f,
            status: allocation.status,
            payroll_item_check_status: allocation.payroll_item.check_status,
            payment_method: allocation.payroll_item.effective_payment_delivery_method,
            remote_allocation_id: allocation.remote_allocation_id,
            last_sync_error: allocation.last_sync_error,
            last_synced_at: allocation.last_synced_at&.iso8601
          }.compact
        end

        def disable_http_caching
          response.headers["Cache-Control"] = "no-store"
          response.headers["Pragma"] = "no-cache"
        end

        def set_pay_period_and_source
          @pay_period = PayPeriod.find_by!(id: params[:pay_period_id], company_id: current_company_id)
          @source = @pay_period.aire_payroll_calendar_period&.time_tracking_source ||
            @pay_period.company.time_tracking_sources.active.find_by(source_type: "aire_services")
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
          require_published_source!
          delegation = current_delegation if with_delegation
          actor = current_user if with_delegation && account_link_connected?
          options = { delegation: delegation }
          options[:actor] = actor if actor
          TimeTracking::Client.new(@source, **options)
        end

        def require_published_source!
          return if @source

          raise TimeTracking::Client::Error.new(
            "Publish this pay period to AIRE before opening its payroll cockpit",
            response_status: 422
          )
        end

        def require_aire_source!
          return if @source

          raise TimeTracking::Client::Error.new(
            "Connect AIRE Services before reviewing manual payroll hours",
            response_status: 422
          )
        end

        def command_access_payload
          delegation = current_delegation
          account_link_configured = account_link_connected?
          {
            can_read: true,
            can_command: StaffRolePolicy.allowed?(current_user, :manage_client_configuration) &&
              (account_link_configured || delegation.present?),
            delegation_configured: account_link_configured || delegation.present?,
            account_link_configured: account_link_configured,
            legacy_delegation_configured: delegation.present?
          }
        end

        def account_link_connected?
          current_account_link.dig("account_link", "connected") == true
        end

        def current_account_link
          return @current_account_link if defined?(@current_account_link)

          @current_account_link = TimeTracking::Client.new(@source, delegation: nil).payroll_account_link(
            external_actor_id: current_user.id
          )
        rescue TimeTracking::Client::Error => e
          Rails.logger.info("AIRE account-link status unavailable: #{e.message}")
          @current_account_link = {}
        end

        def current_delegation
          @current_delegation ||= @source.delegation_for(current_user)
        end

        def command_params
          params.permit(:command_id, :expected_version, :decision, :reason)
        end

        def correction_params
          params.permit(
            :command_id,
            :expected_version,
            :reason,
            :work_date,
            :start_time,
            :end_time,
            :time_category_id,
            :description,
            breaks: %i[start_time end_time]
          )
        end

        def route_params
          params.permit(
            :command_id,
            :expected_version,
            :reason,
            :destination_kind,
            :target_external_pay_period_id,
            :action_due_on
          )
        end

        def routing_options_payload
          @source.aire_payroll_calendar_periods
            .includes(:publications, :payroll_events, :pay_period)
            .joins(:pay_period)
            .where(pay_periods: { cycle: "regular" })
            .where("pay_periods.start_date > ?", @pay_period.end_date)
            .order("pay_periods.start_date ASC, pay_periods.id ASC")
            .filter_map do |calendar_period|
              publication = calendar_period.latest_publication
              next unless publication&.delivered?
              next if calendar_period.payroll_events.any?(&:verified?)

              pay_period = calendar_period.pay_period
              {
                external_pay_period_id: calendar_period.external_pay_period_id,
                pay_period_id: pay_period.id,
                start_date: pay_period.start_date,
                end_date: pay_period.end_date,
                pay_date: pay_period.pay_date
              }
            end
        end

        def bounded_page(key)
          [ params[key].to_i, 1 ].max
        end

        def bounded_per_page(key, maximum:)
          requested = params[key].to_i
          requested = maximum if requested <= 0
          requested.clamp(1, maximum)
        end

        def record_command_audit!(action:, record_type:, record_id:, command_id:, reason:, result:)
          local_record_id = record_id if record_id.to_s.match?(/\A[1-9]\d*\z/)
          AuditLog.record!(
            user: current_user,
            company_id: current_company_id,
            action: action,
            record_type: record_type,
            record_id: local_record_id,
            subject_name: "AIRE payroll command",
            event_category: "payroll",
            metadata: {
              command_id: command_id,
              external_record_id: local_record_id ? nil : record_id,
              reason: reason,
              replayed: result.dig("command", "replayed") == true
            }.compact
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
