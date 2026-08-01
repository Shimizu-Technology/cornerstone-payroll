# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeesController < BaseController
        include Auditable
        audit_actions :reactivate
        before_action :set_employee, only: [ :show, :update, :destroy, :reactivate, :transition_tax_classification ]
        before_action :require_super_admin!, only: :transition_tax_classification

        # GET /api/v1/admin/employees
        def index
          employees = Employee.where(company_id: current_company_id)
          employees = apply_filters(employees)
          employees = apply_sort(employees)
          employees = employees.includes(:department, :employee_wage_rates)
          employees = employees.page(params[:page]).per(params[:per_page] || 25)

          render json: {
            data: employees.map { |e| serialize_employee(e, include_department: true) },
            meta: pagination_meta(employees)
          }
        end

        # GET /api/v1/admin/employees/:id
        def show
          render json: {
            data: serialize_employee(
              @employee,
              include_department: true,
              include_sensitive: true,
              include_classification_history: true
            )
          }
        end

        # POST /api/v1/admin/employees
        def create
          @employee = Employee.new(employee_params.merge(company_id: current_company_id))
          require_ssn_confirmation!(@employee)

          if @employee.save
            render json: { data: serialize_employee(@employee, include_sensitive: true) }, status: :created
          else
            render json: {
              error: "Validation failed",
              details: @employee.errors.messages
            }, status: :unprocessable_entity
          end
        end

        # PATCH /api/v1/admin/employees/:id
        def update
          require_ssn_confirmation!(@employee) if params.dig(:employee, :ssn).present?

          if @employee.update(employee_params)
            render json: { data: serialize_employee(@employee, include_sensitive: true) }
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

        # POST /api/v1/admin/employees/:id/reactivate
        def reactivate
          unless @employee.status == "terminated"
            return render json: { error: "Only terminated employees can be reactivated" }, status: :unprocessable_entity
          end

          @employee.update!(status: "active", termination_date: nil)
          render json: { data: serialize_employee(@employee) }
        end

        # POST /api/v1/admin/employees/:id/transition_tax_classification
        def transition_tax_classification
          result = EmployeeClassificationTransitionService.new(
            employee: @employee,
            attributes: classification_transition_params,
            actor: current_user
          ).call

          render json: {
            data: serialize_employee(
              result.new_employee,
              include_sensitive: true,
              include_classification_history: true
            ),
            previous_employee: employee_link_summary(result.previous_employee),
            message: "New worker record created; historical payroll remains on the prior record"
          }, status: :created
        rescue EmployeeClassificationTransitionService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            error: "Validation failed",
            details: e.record.errors.messages
          }, status: :unprocessable_entity
        end

        private

        def audit_record
          @employee
        end

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
            :salary_type,
            :pay_rate,
            :pay_frequency,
            :filing_status,
            :allowances,
            :additional_withholding,
            :w4_dependent_credit,
            :w4_step2_multiple_jobs,
            :w4_step4a_other_income,
            :w4_step4b_deductions,
            :w4_form_version,
            :w4_effective_on,
            :retirement_rate,
            :roth_retirement_rate,
            :employer_retirement_match_rate,
            :employer_roth_match_rate,
            :business_name,
            :contractor_ein,
            :contractor_type,
            :contractor_pay_type,
            :w9_on_file,
            :address_line1,
            :address_line2,
            :city,
            :state,
            :zip,
            :phone,
            :status,
            default_custom_earnings: [ :label, :amount ],
            default_payroll_adjustments: [ :label, :amount, :treatment, :notes, :active ]
          ).tap do |permitted|
            if permitted.key?(:default_custom_earnings)
              permitted[:default_custom_earnings] = normalize_custom_earnings(permitted[:default_custom_earnings])
            end

            if permitted.key?(:default_payroll_adjustments)
              permitted[:default_payroll_adjustments] = Employee.normalize_payroll_adjustments(permitted[:default_payroll_adjustments])
            end

            if permitted[:ssn].present?
              permitted[:ssn_encrypted] = permitted.delete(:ssn)
            else
              permitted.delete(:ssn)
            end
          end
        end

        def classification_transition_params
          params.require(:transition).permit(
            :employment_type,
            :effective_date,
            :reason,
            :pay_rate,
            :pay_frequency,
            :salary_type,
            :filing_status,
            :contractor_type,
            :contractor_pay_type,
            :business_name,
            :contractor_ein
          )
        end

        def require_ssn_confirmation!(employee)
          employee.require_ssn_confirmation = true
          employee.ssn_confirmation = params.require(:employee).permit(:ssn_confirmation)[:ssn_confirmation]
        end

        def apply_filters(scope)
          scope = scope.where(department_id: params[:department_id]) if params[:department_id].present?
          scope = scope.where(status: params[:status]) if params[:status].present?
          scope = scope.where(employment_type: params[:employment_type]) if params[:employment_type].present?
          if params[:search].present?
            tokens = params[:search].to_s.strip.split(/\s+/).map do |token|
              "%#{ActiveRecord::Base.sanitize_sql_like(token)}%"
            end

            tokens.each do |token|
              scope = scope.where(
                "first_name ILIKE :q OR last_name ILIKE :q OR email ILIKE :q OR CONCAT_WS(' ', first_name, last_name) ILIKE :q",
                q: token
              )
            end
          end
          scope
        end

        def apply_sort(scope)
          sort_by = params[:sort_by].presence_in(%w[name department rate status]) || "name"
          sort_direction = params[:sort_direction].to_s.downcase == "desc" ? :desc : :asc

          if params[:group_by] == "employment_type"
            scope = scope.order(employment_type: :asc)
          end

          case sort_by
          when "department"
            scope.left_joins(:department).order(
              Arel.sql("departments.name IS NULL ASC"),
              department_sort_clause(sort_direction),
              employee_name_sort_clauses(:asc)
            )
          when "rate"
            scope.order(pay_rate: sort_direction, last_name: :asc, first_name: :asc)
          when "status"
            scope.order(status: sort_direction, last_name: :asc, first_name: :asc)
          else
            scope.order(employee_name_sort_clauses(sort_direction))
          end
        end

        def employee_name_sort_clauses(direction)
          { last_name: direction, first_name: direction }
        end

        def department_sort_clause(direction)
          direction == :desc ? Arel.sql("departments.name DESC") : Arel.sql("departments.name ASC")
        end

        def pagination_meta(collection)
          {
            current_page: collection.current_page,
            total_pages: collection.total_pages,
            total_count: collection.total_count,
            per_page: collection.limit_value
          }
        end

        def serialize_employee(
          employee,
          include_department: false,
          include_sensitive: false,
          include_classification_history: false
        )
          data = employee.as_json(
            except: [ :ssn_encrypted, :bank_account_number_encrypted, :bank_routing_number_encrypted ]
          )
          data["ssn_last_four"] = employee.ssn_encrypted&.last(4)
          data["ssn"] = employee.ssn_encrypted if include_sensitive
          data["tax_classification"] = employee.tax_classification
          data["wage_rates"] = employee.active_wage_rates.map do |rate|
            {
              id: rate.id,
              employee_id: rate.employee_id,
              label: rate.label,
              rate: rate.rate,
              is_primary: rate.is_primary,
              active: rate.active
            }
          end

          if include_department && employee.department
            data["department"] = {
              id: employee.department.id,
              name: employee.department.name
            }
          end

          if include_classification_history
            data["classification_history"] = {
              previous_employee: employee_link_summary(employee.previous_employee),
              next_employee: employee_link_summary(employee.next_employee)
            }
          end

          data
        end

        def employee_link_summary(employee)
          return nil unless employee

          {
            id: employee.id,
            name: employee.display_name,
            employment_type: employee.employment_type,
            tax_classification: employee.tax_classification,
            status: employee.status,
            hire_date: employee.hire_date,
            termination_date: employee.termination_date
          }
        end

        def normalize_custom_earnings(entries)
          Array(entries).filter_map do |entry|
            label = entry[:label].to_s.strip
            amount = BigDecimal(entry[:amount].to_s)
            next if label.blank? || amount <= 0 || !amount.finite?

            { "label" => label, "amount" => amount.round(2).to_f }
          rescue ArgumentError, FloatDomainError
            nil
          end
        end
      end
    end
  end
end
