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

          if department.save
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
          if @department.update(department_params)
            render json: { data: serialize_department(@department) }
          else
            render json: {
              error: "Validation failed",
              details: @department.errors.messages
            }, status: :unprocessable_entity
          end
        end

        private

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
