# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeContactChangesToConfirmController < BaseController
        include BoundedListPagination

        before_action :require_profile_requests!

        def index
          scope = filtered_changes
          scope = params[:status] == "confirmed" ? scope.where.not(confirmed_at: nil) : scope.unconfirmed
          through_id = scope.maximum(:id)
          rows = bounded_page(scope.where(id: ..(through_id || 0)).includes(:employee, :changed_by, :confirmed_by).recent_first)
          render json: {
            data: rows.map { |entry| entry.as_activity_json(include_confirmation: true) },
            meta: bounded_page_meta(rows).merge(through_id: through_id)
          }
        end

        def confirm
          entry = company_changes.find_by(id: params[:id])
          return head :not_found unless entry

          confirm_entries(company_changes.where(id: entry.id))
        end

        def confirm_all
          through_id = Integer(params[:through_id].to_s, exception: false)
          unless through_id&.between?(1, 2**63 - 1)
            return render json: { error: "Reload the list before confirming changes." }, status: :unprocessable_entity
          end

          confirm_entries(filtered_changes.where(id: ..through_id))
        end

        private

        def confirm_entries(scope)
          count = EmployeeContactChangeToConfirm.transaction do
            company = Company.lock.find(current_company_id)
            revalidate_current_company_write_access!(company: company)
            now = Time.current
            scope.unconfirmed.update_all(confirmed_at: now, confirmed_by_id: current_user.id, updated_at: now)
          end
          render json: { confirmed_count: count }
        end

        def company_changes
          EmployeeContactChangeToConfirm.payroll_changes.where(company_id: current_company_id)
        end

        def filtered_changes
          scope = company_changes
          scope = scope.where(change_kind: params[:kind]) if params[:kind].present?
          if (search = params[:search].to_s.strip.presence)
            query = "%#{ActiveRecord::Base.sanitize_sql_like(search)}%"
            scope = scope.joins(:employee).where("CONCAT_WS(' ', employees.first_name, employees.last_name) ILIKE ?", query)
          end
          scope
        end

        def require_profile_requests!
          return if CompanyFeatures.for(current_company).employee_portal_feature?(:profile_requests)

          head :not_found
        end
      end
    end
  end
end
