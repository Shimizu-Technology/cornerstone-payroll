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
          # The selected company sets the scope, whatever the request names: a
          # demo company's screen reports on that company alone, never on the
          # live clients across the organization.
          company_id = current_company.id if current_company&.demo?

          report = EmployeeContactHygiene::SharedEmailReport.new(
            actor: current_user,
            organization_id: current_company&.organization_id || current_user.organization_id,
            company_id: company_id
          ).call

          # A contained company (test workspace or demo) may look at the report but never launch a clear.
          render json: report.merge(can_clear: current_company.present? && !current_company.contained?)
        end

        # POST /api/v1/admin/employee_contact_hygiene/placeholder_emails
        def mark_placeholder_email
          organization = resolve_organization
          return render json: { error: "Organization not found" }, status: :not_found unless organization

          result = EmployeeContactHygiene::PlaceholderEmailService.new(
            organization: organization,
            email: params[:email],
            reason: params[:reason],
            actor: current_user,
            company: current_company,
            ip_address: request.remote_ip,
            user_agent: request.user_agent,
            request_id: request.request_id
          ).mark!

          skip_default_audit_log! unless result.changed

          render json: {
            data: {
              email: result.email,
              reason: result.reason,
              marked: result.marked,
              changed: result.changed
            },
            message: result.changed ?
              "Marked #{result.email} as a placeholder email." :
              "#{result.email} is already marked as a placeholder email."
          }
        rescue EmployeeContactHygiene::PlaceholderEmailService::Forbidden => e
          render json: { error: e.message }, status: :forbidden
        rescue EmployeeContactHygiene::PlaceholderEmailService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # DELETE /api/v1/admin/employee_contact_hygiene/placeholder_emails
        def unmark_placeholder_email
          organization = resolve_organization
          return render json: { error: "Organization not found" }, status: :not_found unless organization

          result = EmployeeContactHygiene::PlaceholderEmailService.new(
            organization: organization,
            email: params[:email],
            actor: current_user,
            company: current_company,
            ip_address: request.remote_ip,
            user_agent: request.user_agent,
            request_id: request.request_id
          ).unmark!

          skip_default_audit_log! unless result.changed

          render json: {
            data: {
              email: result.email,
              marked: result.marked,
              changed: result.changed
            },
            message: result.changed ?
              "Removed #{result.email} from the placeholder email list." :
              "#{result.email} was not on the placeholder email list."
          }
        rescue EmployeeContactHygiene::PlaceholderEmailService::Forbidden => e
          render json: { error: e.message }, status: :forbidden
        rescue EmployeeContactHygiene::PlaceholderEmailService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/employee_contact_hygiene/clear_shared_emails
        def clear_shared_emails
          target_company = resolve_target_company
          return render json: { error: "Company not found" }, status: :not_found unless target_company

          # Clear only the client the request explicitly names in X-Company-Id,
          # and only a live one: never the home-company fallback, and a
          # rehearsal can't clear its live source by naming its company ID.
          selected_id = request.headers["X-Company-Id"].to_s
          unless selected_id.present? && authorized_explicit_company_id(selected_id) == target_company.id &&
              !target_company.contained?
            payload = {
              error: target_company.demo? ? Company::DEMO_UNAVAILABLE_MESSAGE : "A practice company (test workspace) is selected, so clearing shared emails is turned off. Switch to a live client to clear its emails."
            }
            payload[:code] = Company::CONTAINED_COMPANY_RESTRICTED_CODE if target_company.contained?
            return render json: payload, status: :forbidden
          end

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

          skip_default_audit_log! if result.cleared_count.zero?

          message = if result.cleared_count.zero?
            "No employee records at #{result.company_name} currently have #{result.email} (0 records changed)."
          else
            "Cleared #{result.email} from #{result.cleared_count} employee #{'record'.pluralize(result.cleared_count)} at #{result.company_name}."
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
            message: message
          }
        rescue EmployeeContactHygiene::ClearSharedEmailService::Forbidden => e
          render json: { error: e.message }, status: :forbidden
        rescue EmployeeContactHygiene::ClearSharedEmailService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def rls_system_reason
          case action_name
          when "shared_emails"
            "Staff shared and placeholder email hygiene summary across accessible companies"
          when "mark_placeholder_email", "unmark_placeholder_email"
            "Staff organization-level placeholder email list update and audit"
          end
        end

        def rls_company_id
          return params[:company_id].to_i if action_name == "clear_shared_emails" && params[:company_id].to_s.match?(/\A[1-9]\d*\z/)

          current_company_id
        end

        def resolve_organization
          org_id = current_company&.organization_id || current_user.organization_id
          Organization.find_by(id: org_id)
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
