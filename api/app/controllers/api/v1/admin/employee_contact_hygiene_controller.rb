# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeContactHygieneController < BaseController
        # GET /api/v1/admin/employee_contact_hygiene/shared_emails
        def shared_emails
          company_id = params[:company_id].presence&.to_i
          if params[:company_id].present?
            unless params[:company_id].to_s.match?(/\A[1-9]\d*\z/) && current_user.can_access_company?(company_id)
              return render json: { error: "You do not have access to this company" }, status: :forbidden
            end
          end

          report = EmployeeContactHygiene::SharedEmailReport.new(
            actor: current_user,
            organization_id: current_company&.organization_id || current_user.organization_id,
            company_id: company_id
          ).call

          render json: report
        end

        # POST /api/v1/admin/employee_contact_hygiene/clear_shared_emails
        def clear_shared_emails
          target_company = resolve_target_company
          return render json: { error: "Company not found" }, status: :not_found unless target_company

          unless current_user.can_access_company?(target_company.id) &&
              StaffRolePolicy.allowed?(current_user, :manage_client_configuration, company: target_company)
            return render json: { error: StaffRolePolicy.error_message(:manage_client_configuration) }, status: :forbidden
          end

          result = nil
          TenantScope.with_company(target_company.id) do
            Employee.transaction do
              target_company.lock!
              revalidate_current_company_write_access!(company: target_company, capability: :manage_client_configuration)
              result = EmployeeContactHygiene::ClearSharedEmailService.new(
                company: target_company,
                email: params[:email],
                actor: current_user,
                ip_address: request.remote_ip,
                user_agent: request.user_agent,
                request_id: request.request_id
              ).call!
            end
          end

          render json: {
            data: {
              company_id: result.company_id,
              company_name: result.company_name,
              email: result.email,
              cleared_count: result.cleared_count,
              active_cleared_count: result.active_cleared_count,
              inactive_cleared_count: result.inactive_cleared_count
            },
            message: "Cleared #{result.email} from #{result.cleared_count} employee #{'record'.pluralize(result.cleared_count)} at #{result.company_name}."
          }
        rescue EmployeeContactHygiene::ClearSharedEmailService::Forbidden => e
          render json: { error: e.message }, status: :forbidden
        rescue EmployeeContactHygiene::ClearSharedEmailService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def rls_system_reason
          return "Staff shared and placeholder email hygiene summary across accessible companies" if action_name == "shared_emails"

          nil
        end

        def rls_company_id
          return params[:company_id].to_i if action_name == "clear_shared_emails" && params[:company_id].to_s.match?(/\A[1-9]\d*\z/)

          current_company_id
        end

        def resolve_target_company
          if params[:company_id].present?
            return nil unless params[:company_id].to_s.match?(/\A[1-9]\d*\z/)

            Company.find_by(id: params[:company_id].to_i)
          else
            current_company
          end
        end
      end
    end
  end
end
