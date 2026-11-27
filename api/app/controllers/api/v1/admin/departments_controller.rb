# frozen_string_literal: true

module Api
  module V1
    module Admin
      class DepartmentsController < BaseController
        before_action :set_department, only: [ :update ]

        # GET /api/v1/admin/departments
        def index
          departments = Department.where(company_id: current_company_id)
          departments = departments.where(active: params[:active]) if params[:active].present?
          departments = departments.left_joins(:employees)
                                   .select("departments.*, COUNT(employees.id) as employee_count")
                                   .group("departments.id")
                                   .order(:name)

          render json: {
            data: departments.map { |d| serialize_department(d) }
          }
        end

        # POST /api/v1/admin/departments
        def create
          department = Department.new(department_params.merge(company_id: current_company_id))

          if write_department(department) { department.save }
            render json: { data: serialize_department(department) }, status: :created
          else
            render json: {
              error: "Validation failed",
              details: department.errors.messages
            }, status: :unprocessable_entity
          end
        end

        # PATCH /api/v1/admin/departments/:id
        def update
          if write_department(@department) { @department.update(department_params) }
            render json: { data: serialize_department(@department) }
          else
            render json: {
              error: "Validation failed",
              details: @department.errors.messages
            }, status: :unprocessable_entity
          end
        end

        private

        def write_department(department)
          current_company.with_lock(requires_new: true) do
            authorize_department_write!
            before = department.persisted? ? department.reload.slice("name", "active") : {}
            saved = yield
            after = department.slice("name", "active")
            if saved && before != after
              record_type = controller_path.start_with?("api/v1/client/") ? "client_departments" : "departments"
              EmployeeOrganization.audit!(department, actor: current_user, before: before, after: after,
                action: "#{record_type}##{action_name}", record_type: record_type)
              department.employees.where(company_id: current_company.id).find_each do |employee|
                EmployeeOrganization.audit!(employee, actor: current_user, before: before.transform_keys { |key| "department_#{key}" },
                  after: after.transform_keys { |key| "department_#{key}" })
              end
            end
            saved
          end
        end

        def authorize_department_write!
          revalidate_current_company_write_access!
        end

        def set_department
          @department = Department.find_by(id: params[:id], company_id: current_company_id)
          return if @department

          render json: { error: "Department not found" }, status: :not_found
        end

        def department_params
          params.require(:department).permit(:name, :active)
        end

        def serialize_department(department)
          data = department.as_json
          # Add employee_count if it was selected
          if department.respond_to?(:employee_count)
            data["employee_count"] = department.employee_count.to_i
          else
            data["employee_count"] = department.employees.count
          end
          data
        end
      end
    end
  end
end
