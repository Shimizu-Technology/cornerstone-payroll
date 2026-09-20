# frozen_string_literal: true

module Api
  module V1
    module Admin
      # A live, non-payable inbox. An AIRE user is not a payroll employee until
      # an administrator explicitly links an existing profile or completes one.
      class AireEmployeeCandidatesController < BaseController
        before_action :require_manager_or_admin!, only: :link
        before_action :disable_http_caching

        def index
          source = aire_source
          return render json: { connected: false, employees: [], pagination: empty_pagination } unless source

          payload = TimeTracking::Client.new(source).payroll_cockpit_employees(
            page: bounded_page,
            per_page: 100,
            active: true,
            employee_id: params[:employee_id]
          )
          decorated = AirePayrollCockpit::Presenter.new(source: source).employees(payload)
          decorate_possible_matches!(decorated.fetch(:employees))
          render json: decorated.merge(connected: true)
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        def link
          source = aire_source
          unless source
            return render json: { error: "Connect AIRE before linking its people to payroll" }, status: :unprocessable_entity
          end

          mapping = TimeTracking::EmployeeMappingService.new(company: current_company, source: source).link!(
            source_user_id: params.require(:source_user_id),
            employee_id: params.require(:employee_id)
          )
          render json: {
            mapping: {
              source_user_id: mapping.source_user_id,
              source_user_uuid: mapping.source_user_uuid,
              employee_id: mapping.employee_id,
              employee_name: mapping.employee.full_name
            }
          }
        rescue ActionController::ParameterMissing, ArgumentError, ActiveRecord::RecordNotFound,
               ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique,
               TimeTracking::EmployeeMappingService::Error, TimeTrackingEmployeeMapping::IdentityConflict => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue TimeTracking::Client::Error => e
          render_source_error(e)
        end

        private

        def aire_source
          @aire_source ||= current_company.time_tracking_sources.active.find_by(source_type: "aire_services")
        end

        def bounded_page
          [ params[:page].to_i, 1 ].max
        end

        def empty_pagination
          { current_page: 1, per_page: 100, total_count: 0, total_pages: 1, truncated: false }
        end

        def decorate_possible_matches!(people)
          payroll_employees = current_company.employees.select(:id, :first_name, :middle_name, :last_name, :status, :email).to_a
          people.each do |person|
            next unless person.dig("cornerstone", "status") == "unmapped"

            name = normalized_name(person["first_name"], person["last_name"])
            email = person["email"].to_s.strip.downcase
            person["possible_payroll_matches"] = payroll_employees.filter_map do |employee|
              same_name = name.present? && normalized_name(employee.first_name, employee.last_name) == name
              same_email = email.present? && employee.email.to_s.strip.downcase == email
              next unless same_name || same_email

              { id: employee.id, name: employee.full_name, status: employee.status }
            end
          end
        end

        def normalized_name(first_name, last_name)
          return if first_name.blank? || last_name.blank?

          "#{first_name} #{last_name}".squish.downcase
        end

        def disable_http_caching
          response.headers["Cache-Control"] = "no-store"
          response.headers["Pragma"] = "no-cache"
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
