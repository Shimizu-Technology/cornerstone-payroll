# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeesController < BaseController
        before_action :set_employee, only: [ :show, :update, :destroy ]

        # GET /api/v1/admin/employees
        def index
          employees = Employee.where(company_id: current_company_id)
          employees = apply_filters(employees)
          employees = employees.includes(:department).order(:last_name, :first_name)
          employees = employees.page(params[:page]).per(params[:per_page] || 25)

          render json: {
            data: employees.map { |e| serialize_employee(e) },
            meta: pagination_meta(employees)
          }
        end

        # GET /api/v1/admin/employees/:id
        def show
          render json: {
            data: serialize_employee(@employee, include_department: true)
          }
        end

        # POST /api/v1/admin/employees
        def create
          employee = Employee.new(employee_params.merge(company_id: current_company_id))

          if employee.save
            render json: { data: serialize_employee(employee) }, status: :created
          else
            render json: {
              error: "Validation failed",
              details: employee.errors.messages
            }, status: :unprocessable_entity
          end
        end

        # PATCH /api/v1/admin/employees/:id
        def update
          if @employee.update(employee_params)
            render json: { data: serialize_employee(@employee) }
          else
            render json: {
              error: "Validation failed",
              details: @employee.errors.messages
            }, status: :unprocessable_entity
          end
        end

        # DELETE /api/v1/admin/employees/:id
        def destroy
          @employee.update!(status: "terminated", termination_date: Date.current)
          head :no_content
        end

        private

        def set_employee
          @employee = Employee.find_by(id: params[:id], company_id: current_company_id)
          return if @employee

          render json: { error: "Employee not found" }, status: :not_found
        end

        def employee_params
          params.require(:employee).permit(
            :first_name,
            :middle_name,
            :last_name,
            :email,
            :ssn,
            :date_of_birth,
            :hire_date,
            :termination_date,
            :department_id,
            :job_title,
            :employment_type,
            :pay_rate,
            :pay_frequency,
            :filing_status,
            :allowances,
            :additional_withholding,
            :retirement_rate,
            :roth_retirement_rate,
            :address_line1,
            :address_line2,
            :city,
            :state,
            :zip,
            :phone,
            :status
          ).tap do |permitted|
            # Map :ssn to :ssn_encrypted for the encrypted field
            if permitted[:ssn].present?
              permitted[:ssn_encrypted] = permitted.delete(:ssn)
            end
          end
        end

        def apply_filters(scope)
          scope = scope.where(department_id: params[:department_id]) if params[:department_id].present?
          scope = scope.where(status: params[:status]) if params[:status].present?
          if params[:search].present?
            search_term = "%#{params[:search]}%"
            scope = scope.where(
              "first_name ILIKE :q OR last_name ILIKE :q OR email ILIKE :q",
              q: search_term
            )
          end
          scope
        end

        def pagination_meta(collection)
          {
            current_page: collection.current_page,
            total_pages: collection.total_pages,
            total_count: collection.total_count,
            per_page: collection.limit_value
          }
        end

        def serialize_employee(employee, include_department: false)
          data = employee.as_json(
            except: [ :ssn_encrypted, :bank_account_number_encrypted, :bank_routing_number_encrypted ]
          )
          data["ssn_last_four"] = employee.ssn_encrypted&.last(4)

          if include_department && employee.department
            data["department"] = {
              id: employee.department.id,
              name: employee.department.name
            }
          end

          data
        end
      end
    end
  end
end
