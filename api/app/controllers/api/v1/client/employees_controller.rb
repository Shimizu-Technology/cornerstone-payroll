# frozen_string_literal: true

module Api
  module V1
    module Client
      class EmployeesController < BaseController
        before_action :set_employee, only: [ :show, :update ]

        def index
          employees = Employee.where(company_id: current_company_id)
          employees = apply_filters(employees)
          employees = apply_sort(employees)
          employees = employees.includes(:department, :employee_wage_rates)
          employees = employees.page(params[:page]).per(params[:per_page] || 25)

          render json: {
            data: employees.map { |employee| serialize_employee(employee) },
            meta: pagination_meta(employees)
          }
        end

        def show
          render json: {
            data: serialize_employee(@employee, include_department: true, include_sensitive: true)
          }
        end

        def create
          employee = Employee.new
          result = ClientEmployeeUpdateService.new(
            employee: employee,
            attrs: employee_params.to_h,
            requested_by: current_user,
            company: current_company
          ).create!

          audit_employee_action!(
            action: "client_employees#create",
            record_id: result.employee.id,
            metadata: audit_metadata_for(result)
          )

          render json: {
            data: serialize_employee(result.employee),
            message: "Employee created successfully"
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            error: "Validation failed",
            details: e.record.errors.messages
          }, status: :unprocessable_entity
        end

        def update
          result = ClientEmployeeUpdateService.new(
            employee: @employee,
            attrs: employee_params.to_h,
            requested_by: current_user,
            company: current_company
          ).update!

          audit_employee_action!(
            action: "client_employees#update",
            record_id: result.employee.id,
            metadata: audit_metadata_for(result)
          )

          render json: {
            data: serialize_employee(result.employee),
            applied_direct_fields: result.applied_direct_fields,
            message: "Employee updated successfully"
          }
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            error: "Validation failed",
            details: e.record.errors.messages
          }, status: :unprocessable_entity
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
            default_payroll_adjustments: [ :label, :amount, :treatment, :notes, :active ],
            wage_rates: [ :id, :label, :rate, :is_primary, :active ]
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

        def serialize_employee(employee, include_department: false, include_sensitive: false)
          data = employee.as_json(
            except: [ :ssn_encrypted, :bank_account_number_encrypted, :bank_routing_number_encrypted ]
          )
          data["ssn_last_four"] = employee.ssn_last_four
          data["ssn"] = employee.ssn_encrypted if include_sensitive
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

          data
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

        def audit_metadata_for(result)
          {
            source: "client_portal",
            employee_name: result.employee.display_name,
            changed_fields: result.changed_fields,
            before_values: sanitized_audit_values(result.before_values),
            after_values: sanitized_audit_values(result.after_values)
          }
        end

        def sanitized_audit_values(values)
          values.each_with_object({}) do |(key, value), acc|
            acc[key] =
              case key.to_s
              when "ssn_encrypted", "contractor_ein"
                mask_tax_identifier(value)
              else
                value
              end
          end
        end

        def mask_tax_identifier(value)
          digits = value.to_s.gsub(/\D/, "")
          return "Updated" if digits.blank?
          return "***-**-#{digits.last(4)}" if digits.length == 9

          "Ending in #{digits.last(4)}"
        end

        def audit_employee_action!(action:, record_id:, metadata:)
          AuditLog.record!(
            user: current_user,
            company_id: current_company_id,
            action: action,
            record_type: "employees",
            record_id: record_id,
            metadata: metadata,
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          )
        rescue StandardError => e
          Rails.logger.warn("[ClientEmployeesController] Audit log failed: #{e.message}")
        end
      end
    end
  end
end
