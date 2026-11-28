# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeVerificationItemsController < BaseController
        include StaffEmployeeLifecycleAccess
        include BoundedListPagination

        rescue_from EmployeeVerificationItems::Review::Conflict do |error|
          render json: { error: error.message, code: "verification_item_changed" }, status: :conflict
        end

        rescue_from EmployeeVerificationItems::Review::Invalid, ActiveRecord::RecordInvalid do |error|
          render json: { error: error.message }, status: :unprocessable_content
        end

        rescue_from ActiveRecord::RecordNotFound do
          render json: { error: "Verification item not found" }, status: :not_found
        end

        def index
          skip_default_audit_log! if request.post?
          items = verification_items.order(updated_at: :desc, id: :desc)
          filters = params.permit(:status, :event_kind, :employee_id, :affects_pay).to_h.compact_blank
          return render json: { error: "affects_pay must be true or false" }, status: :unprocessable_content if
            filters.key?("affects_pay") && !filters["affects_pay"].to_s.in?(%w[true false])

          items = items.where(filters)
          search = request.request_parameters["employee_search"] if request.post?
          if search.is_a?(String) && search.strip.present?
            term = Employee.sanitize_sql_like(search.strip)
            search_bind = ActiveRecord::Relation::QueryAttribute.new("employee_search", "%#{term}%", ActiveRecord::Type::String.new)
            items = items.joins(:employee).where("CONCAT_WS(' ', employees.first_name, employees.last_name) ILIKE ?", Arel::Nodes::BindParam.new(search_bind))
          end

          page = bounded_page(items)
          render json: {
            data: page.map { |item| EmployeeVerificationItems::StaffDetails.summary(item) },
            meta: bounded_page_meta(page)
          }
        end

        def show
          render json: { data: details_for(verification_items.find(params[:id])) }
        end

        def verify
          review!(:verify)
        end

        def return_to_client
          review!(:return_to_client)
        end

        private

        def verification_items
          EmployeeVerificationItem.where(company_id: current_company_id).includes(:employee, :source_actor)
        end

        def details_for(item)
          EmployeeVerificationItems::StaffDetails.new(item, viewer: current_user).as_json
        end

        def review!(operation)
          skip_default_audit_log!
          item = EmployeeVerificationItems::Review.new(company_id: current_company_id, item_id: params[:id], actor: current_user)
            .call!(operation, params.permit(:verification_note, :return_note, :fixed_by_staff, :staff_edit_audit_id, :updated_at)) do |company|
              revalidate_current_company_write_access!(company: company, capability: :manage_client_configuration)
              raise CompanyWriteAccessChanged unless staff_employee_lifecycle_available?(company)
            end
          render json: { data: details_for(item) }
        end
      end
    end
  end
end
