# frozen_string_literal: true

module Api
  module V1
    class CompaniesController < ApplicationController
      include CompanyRlsScoped
      def index
        return render json: { error: "Not authenticated" }, status: :unauthorized unless current_user

        companies = Company.includes(:organization, :migration_source_company, :created_by).where(id: current_user.accessible_company_ids)
                           .yield_self { |scope| params[:active].present? ? scope.where(active: ActiveModel::Type::Boolean.new.cast(params[:active])) : scope }
                           .order(:name)
        companies = companies.where(id: Current.view_as_grant.company_id) if Current.view_as_grant
        @creators = RecordCreator.for_companies(companies.to_a) if StaffRolePolicy.allowed?(current_user, :staff_workspace)
        company_ids = companies.pluck(:id)
        total_employee_counts = employee_counts_by_company(company_ids)
        active_employee_counts = employee_counts_by_company(company_ids, active_only: true)

        render json: {
          companies: companies.map do |company|
            company_summary(
              company,
              total_employee_counts: total_employee_counts,
              active_employee_counts: active_employee_counts
            )
          end,
          can_manage_clients: current_user.organization_admin?,
          # Matches Admin::CompaniesController#staff_client_access? so assigned
          # managers and accountants can find the client edit page.
          can_view_client_management: current_user.organization_admin? || current_user.manager? || current_user.accountant?,
          can_switch_company: !Current.view_as_grant && current_user.accessible_company_ids.size > 1,
          # Firm finance (books, invoices, customer links) may target live
          # clients only; navigation keeps every accessible company.
          billing_company_ids: companies.select(&:live_payroll?).map(&:id),
          current_company_id: company_ids.include?(current_company_id) ? current_company_id : company_ids.first
        }
      end

      private

      def rls_system_reason
        "Count employees across the signed-in user's accessible companies"
      end

      def company_summary(company, total_employee_counts:, active_employee_counts:)
        summary = {
          id: company.id,
          organization_id: company.organization_id,
          organization_name: company.organization&.name,
          name: company.name,
          active: company.active,
          active_employees: active_employee_counts.fetch(company.id, 0),
          total_employees: total_employee_counts.fetch(company.id, 0),
          pay_frequency: company.pay_frequency,
          payroll_intake_source_types: company.payroll_intake_source_types,
          historical_payroll_enabled: company.historical_payroll_enabled,
          client_capabilities: StaffRolePolicy.capabilities_for(current_user, company: company),
          client_management: StaffRolePolicy.client_management_allowed?(current_user, company),
          **CompanyWorkspacePresentation.fields(company),
          practice_portal: current_user.client? && current_user.practice_company_id == company.id,
          workspace_can_write: company_write_allowed?(company),
          workspace_write_permissions: workspace_write_permissions(company)
        }
        summary[:creator] = @creators[company.id] if @creators
        summary
      end

      def company_write_allowed?(company)
        return false if Current.view_as_grant

        return false unless current_user.payroll_access_allowed? && company.active? && company.organization&.active? && current_user.can_access_company?(company.id)
        return true unless company.test_workspace?

        StaffRolePolicy.allowed?(current_user, :payroll_operations) &&
          TestWorkspaceAccessPolicy.allowed?(user: current_user, company: company, request_method: "POST", capability: :payroll_operations)
      end

      def workspace_write_permissions(company)
        return nil unless company.test_workspace?

        accessible = !!(current_user.payroll_access_allowed? && company.active? && company.organization&.active? && current_user.can_access_company?(company.id))
        StaffRolePolicy::CAPABILITY_ROLES.keys.index_with do |capability|
          accessible && StaffRolePolicy.allowed?(current_user, capability) &&
            TestWorkspaceAccessPolicy.allowed?(user: current_user, company: company, request_method: "POST", capability: capability)
        end
      end

      def employee_counts_by_company(company_ids, active_only: false)
        return {} if company_ids.empty?

        scope = Employee.where(company_id: company_ids)
        scope = scope.active if active_only
        scope.group(:company_id).count
      end
    end
  end
end
