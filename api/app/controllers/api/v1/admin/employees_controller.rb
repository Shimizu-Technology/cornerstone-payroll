# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeesController < BaseController
        include Auditable
        audit_actions :terminate, :reactivate
        before_action :set_employee, only: [
          :show, :update, :destroy, :terminate, :reactivate, :transition_tax_classification,
          :resolve_configuration_review_item
        ]
        before_action :validate_department_scope!, only: [ :create, :update ]
        before_action :require_super_admin!, only: :transition_tax_classification
        before_action :require_manager_or_admin!, only: [ :terminate, :reactivate ]

        # GET /api/v1/admin/employees
        def index
          employees = Employee.where(company_id: current_company_id)
          employees = apply_filters(employees)
          employees = apply_sort(employees)
          employees = employees.includes(:department, :employee_wage_rates, :employee_work_profiles)
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
              include_classification_history: true,
              include_lifecycle: true,
              include_w4_history: true,
              include_retirement_history: true,
              include_configuration_review_history: true
            )
          }
        end

        # POST /api/v1/admin/employees
        def create
          attributes, w4_attributes, w4_reason = split_w4_attributes(employee_params)
          @employee = Employee.new(attributes.merge(w4_attributes).merge(company_id: current_company_id))
          require_ssn_confirmation!(@employee)

          Employee.transaction do
            @employee.save!
            EmployeeW4ElectionChangeService.new(
              employee: @employee,
              attributes: EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| @employee.public_send(attribute) },
              actor: current_user,
              source: "employee_creation",
              reason: w4_reason
            ).call!
          end

          render json: { data: serialize_employee(@employee, include_sensitive: true, include_w4_history: true) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            error: "Validation failed",
            details: e.record.errors.messages
          }, status: :unprocessable_entity
        rescue EmployeeW4ElectionChangeService::Error => e
          render json: { error: "Validation failed", details: { w4_effective_on: [ e.message ] } }, status: :unprocessable_entity
        end

        # PATCH /api/v1/admin/employees/:id
        def update
          attributes, w4_attributes, w4_reason = split_w4_attributes(employee_params)
          require_ssn_confirmation!(@employee) if params.dig(:employee, :ssn).present? && params.dig(:employee, :ssn).to_s.gsub(/\D/, "") != @employee.ssn_digits

          Employee.transaction do
            @employee.update!(attributes.merge(w4_attributes))
            EmployeeW4ElectionChangeService.new(
              employee: @employee,
              attributes: w4_attributes,
              actor: current_user,
              source: "staff",
              reason: w4_reason
            ).call!
          end

          render json: { data: serialize_employee(@employee, include_sensitive: true, include_w4_history: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            error: "Validation failed",
            details: e.record.errors.messages
          }, status: :unprocessable_entity
        rescue EmployeeW4ElectionChangeService::Error => e
          render json: { error: "Validation failed", details: { w4_change_reason: [ e.message ] } }, status: :unprocessable_entity
        end

        # DELETE /api/v1/admin/employees/:id
        def destroy
          render json: {
            error: "Use the termination workflow so the effective date and audit history are recorded"
          }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/employees/:id/terminate
        def terminate
          EmployeeStatusTransitionService.terminate!(
            employee: @employee,
            actor: current_user,
            attributes: termination_params
          )
          render json: { data: serialize_employee(@employee.reload, include_lifecycle: true) }
        rescue EmployeeStatusTransitionService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/employees/:id/reactivate
        def reactivate
          EmployeeStatusTransitionService.reactivate!(
            employee: @employee,
            actor: current_user,
            attributes: reactivation_params
          )
          render json: { data: serialize_employee(@employee.reload, include_lifecycle: true) }
        rescue EmployeeStatusTransitionService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
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

        def resolve_configuration_review_item
          EmployeeConfigurationReviewService.new(employee: @employee, actor: current_user).resolve!(
            code: params.require(:code),
            resolution_note: params.fetch(:resolution_note, ""),
            acknowledgement: params.require(:acknowledgement)
          )
          render json: {
            data: serialize_employee(
              @employee.reload,
              include_department: true,
              include_sensitive: true,
              include_classification_history: true,
              include_lifecycle: true,
              include_w4_history: true,
              include_configuration_review_history: true
            )
          }
        rescue EmployeeConfigurationReviewService::NotAuthorized => e
          render json: { error: e.message }, status: :forbidden
        rescue ActionController::ParameterMissing, EmployeeConfigurationReviewService::InvalidResolution,
               ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
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

        def validate_department_scope!
          department_id = params.dig(:employee, :department_id)
          return if department_id.blank?
          return if Department.exists?(id: department_id, company_id: current_company_id)

          render json: {
            error: "Validation failed",
            details: { department_id: [ "does not belong to this company" ] }
          }, status: :unprocessable_entity
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
            :w4_signed_on,
            :w4_source_reference,
            :w4_effective_on,
            :w4_change_reason,
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

        def split_w4_attributes(permitted)
          attributes = permitted.to_h.symbolize_keys
          reason = attributes.delete(:w4_change_reason)
          w4_attributes = attributes.extract!(*EmployeeW4Election::PROFILE_ATTRIBUTES)
          [ attributes, w4_attributes, reason ]
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
            :ssn,
            :ssn_confirmation,
            :contractor_type,
            :contractor_pay_type,
            :business_name,
            :contractor_ein
          )
        end

        def termination_params
          params.require(:termination).permit(
            :effective_date,
            :last_worked_on,
            :reason_category,
            :internal_notes
          )
        end

        def reactivation_params
          params.require(:reactivation).permit(:effective_date, :internal_notes)
        end

        def require_ssn_confirmation!(employee)
          employee.require_ssn_confirmation = true
          employee.ssn_confirmation = params.require(:employee).permit(:ssn_confirmation)[:ssn_confirmation]
        end

        def apply_filters(scope)
          scope = scope.where(department_id: params[:department_id]) if params[:department_id].present?
          scope = scope.where(status: params[:status]) if params[:status].present?
          scope = scope.where(employment_type: params[:employment_type]) if params[:employment_type].present?
          if params[:configuration_review_status].present?
            allowed_status = params[:configuration_review_status].presence_in(Employee::CONFIGURATION_REVIEW_STATUSES)
            scope = scope.where(configuration_review_status: allowed_status) if allowed_status
          end
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
          include_classification_history: false,
          include_lifecycle: false,
          include_w4_history: false,
          include_retirement_history: false,
          include_configuration_review_history: false
        )
          data = employee.as_json(
            except: [ :ssn_encrypted, :bank_account_number_encrypted, :bank_routing_number_encrypted ]
          )
          data["ssn_last_four"] = employee.ssn_encrypted&.last(4)
          data["ssn"] = employee.ssn_encrypted if include_sensitive
          data["tax_classification"] = employee.tax_classification
          current_profile = if employee.association(:employee_work_profiles).loaded?
            employee.employee_work_profiles.find { |profile| profile.ends_on.nil? }
          else
            employee.employee_work_profiles.find_by(ends_on: nil)
          end
          data["current_work_profile"] = serialize_work_profile(current_profile)
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

          if include_lifecycle
            data["status_history"] = employee.employee_status_events.order(effective_date: :desc, id: :desc).map do |event|
              serialize_status_event(event)
            end
          end

          if include_w4_history
            elections = employee.employee_w4_elections.includes(:created_by).recent_first.to_a
            latest_election = elections.first
            data.merge!(latest_election.profile_attributes.stringify_keys) if latest_election
            data["w4_elections"] = elections.map { |election| serialize_w4_election(election) }
            data["current_w4_election"] = serialize_w4_election(employee.w4_election_on(Date.current))
            data["upcoming_w4_election"] = serialize_w4_election(
              elections.select { |election| election.effective_on > Date.current }.min_by { |election| [ election.effective_on, election.id ] }
            )
          end

          if include_retirement_history
            elections = employee.employee_retirement_elections.includes(:created_by).recent_first.to_a
            data["retirement_elections"] = elections.map { |election| serialize_retirement_election(election) }
            data["current_retirement_election"] = serialize_retirement_election(employee.retirement_election_on(Date.current))
            data["upcoming_retirement_election"] = serialize_retirement_election(
              elections.select { |election| election.effective_on > Date.current }.min_by { |election| [ election.effective_on, election.id ] }
            )
          end

          if include_configuration_review_history
            data["configuration_review_resolutions"] = employee.employee_configuration_review_resolutions
              .order(reviewed_at: :desc, id: :desc).map do |resolution|
                resolution.as_json(except: [ :company_id, :employee_id, :reviewed_by_id ]).merge(
                  "reviewed_by_name" => resolution.reviewed_by_name
                )
              end
          end

          data
        end

        def serialize_w4_election(election)
          return nil unless election

          election.as_json(except: [ :created_by_id ]).merge(
            "created_by_name" => election.created_by&.name
          )
        end

        def serialize_retirement_election(election)
          return nil unless election

          election.as_json(except: [ :created_by_id ]).merge(
            "created_by_name" => election.created_by&.name
          )
        end

        def serialize_work_profile(profile)
          return nil unless profile

          profile.as_json(except: [ :notes ]).merge(
            "notes" => can_view_restricted_lifecycle_notes? ? profile.notes : nil
          )
        end

        def serialize_status_event(event)
          event.as_json(except: [ :internal_notes ]).merge(
            "actor_name" => event.actor&.name,
            "internal_notes" => can_view_restricted_lifecycle_notes? ? event.internal_notes : nil
          )
        end

        def can_view_restricted_lifecycle_notes?
          current_user&.organization_admin? || current_user&.manager?
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
