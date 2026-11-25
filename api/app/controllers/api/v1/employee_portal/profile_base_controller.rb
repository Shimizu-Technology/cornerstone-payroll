# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      class ProfileBaseController < BaseController
        include RecentVerification

        before_action :require_profile_access!, :load_employee
        before_action :require_active_link!, if: :profile_write?
        around_action :with_profile_write, if: :profile_write?

        rescue_from ActiveRecord::RecordNotFound do
          head :not_found
        end

        rescue_from ActiveRecord::RecordInvalid do |error|
          render json: { error: "Validation failed", details: error.record.errors.messages }, status: :unprocessable_entity
        end

        private

        attr_reader :current_user

        def profile_write?
          !request.get? && !request.head?
        end

        def current_company
          @employee_link.company
        end

        def require_profile_access!
          response.set_header("Cache-Control", "no-store")
          head :not_found unless CompanyFeatures.for(current_company).employee_portal_feature?(:profile_requests)
        end

        def load_employee
          @employee = Employee.where(company_id: current_company_id).find(@employee_link.employee_id)
        end

        def require_active_link!
          head :not_found unless @employee_link.active?
        end

        def with_profile_write
          Employee.transaction(requires_new: true) do
            lock_profile_company!
            @employee.lock!
            # Link retirement locks the employee and then the login before
            # the link. The login lock also keeps the role stable for step-up.
            current_user.lock!("FOR NO KEY UPDATE")
            @employee_link.lock!
            unless writable_link?
              head :not_found
              next
            end

            require_recent_verification!
            unless performed?
              yield
              audit_profile_write! if response.successful?
            end
          end
        end

        def writable_link?
          current_user.payroll_access_allowed? && @employee_link.active? && @employee_link.user_id == current_user.id &&
            @employee_link.employee_id == @employee.id && @employee_link.company_id == @employee.company_id
        end

        def lock_profile_company!
          # Take the company FK lock before the employee lock used by the client writer.
          Company.lock("FOR KEY SHARE").find(current_company_id)
        end

        def profile
          @profile ||= EmployeeProfiles::Profile.new(@employee_link, @employee)
        end

        def render_profile(status: :ok)
          render json: profile.as_json, status: status
        end

        def audit_record
          @audit_record || @employee
        end

        def audit_record_metadata(_record)
          { employee_id: @employee.id, employee_link_id: @employee_link.id }
        end

        def audit_profile_write!
          record = audit_record
          AuditLog.record!(
            user: current_user, company_id: current_company_id, record_type: record.class.table_name, record_id: record.id,
            action: "#{controller_path.delete_prefix('api/v1/')}##{action_name}", metadata: audit_record_metadata(record)
          )
        end

        def resource_id
          id = params[:id]
          raise ActiveRecord::RecordNotFound unless id.is_a?(String) && id.match?(/\A[1-9]\d{0,18}\z/) && id.to_i <= 2**63 - 1

          id
        end

        def invalid!(field, reason)
          @employee.errors.add(field, reason)
          raise ActiveRecord::RecordInvalid, @employee
        end
      end
    end
  end
end
