# frozen_string_literal: true

module Api
  module V1
    module Client
      class EmployeesController < BaseController
        SENSITIVE_CHANGE_REQUEST_KEYS = %w[ssn ssn_encrypted contractor_ein sensitive_payload_encrypted].freeze
        DEFAULT_PER_PAGE = 25
        MAX_PER_PAGE = 500
        AUDIT_FAILURE_MESSAGE = "This change was not saved because its activity record could not be written. Please try again."

        class AuditWriteFailed < StandardError; end

        before_action :reject_closed_practice_copy, only: [ :create, :update ]
        before_action :set_employee, only: [ :show, :update ]

        def index
          contact_context = EmployeeContactValidator.contact_details_context(company: current_company)
          employees = Employee.where(company_id: current_company_id)
          employees = apply_filters(employees)
          needs_contact_details_count = employees.needs_contact_details(flagged_emails: contact_context[:flagged_emails]).count
          if needs_contact_details_filter_active?
            employees = employees.needs_contact_details(flagged_emails: contact_context[:flagged_emails])
          end
          employees = apply_sort(employees)
          employees = employees.includes(:department, :employee_wage_rates, :employee_w4_elections)
            .preload(:employee_wage_rate_versions, :employee_compensation_changes)
          employees = employees.page(params[:page]).per(bounded_per_page(default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE))

          render json: {
            data: employees.map { |employee| serialize_employee(employee, contact_context: contact_context) },
            meta: pagination_meta(employees).merge(needs_contact_details_count: needs_contact_details_count)
          }
        end

        def show
          contact_context = EmployeeContactValidator.contact_details_context(company: current_company)
          render json: {
            data: serialize_employee(@employee, include_department: true, include_document_readiness: true, contact_context: contact_context)
          }
        end

        def create
          employee = Employee.new
          require_ssn_confirmation!(employee)
          result = with_employee_audit(action: "client_employees#create") do
            ClientEmployeeUpdateService.new(
              employee: employee,
              attrs: employee_params.to_h,
              requested_by: current_user,
              company: current_company,
              confirm_same_person_email: confirm_same_person_email_param
            ).create!
          end

          contact_context = EmployeeContactValidator.contact_details_context(company: current_company)
          render json: {
            data: serialize_employee(result.employee, contact_context: contact_context),
            change_request: serialize_change_request(result.change_request),
            applied_direct_fields: result.applied_direct_fields,
            contact_warnings: result.contact_warnings || [],
            message: "Employee profile created. Payroll-sensitive details were submitted for approval as request ##{result.change_request.id}."
          }, status: :created
        rescue EmployeeContactValidator::ValidationError => e
          render json: {
            error: "Validation failed",
            details: e.record.errors.messages,
            contact_validation: e.result.contact_validation_payload
          }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            error: "Validation failed",
            details: e.record.errors.messages
          }, status: :unprocessable_entity
        rescue LegacyRecurringComponentGuard::Error => e
          render json: { error: "Validation failed", details: { payroll_components: [ e.message ] } }, status: :unprocessable_entity
        rescue AuditWriteFailed
          render json: { error: AUDIT_FAILURE_MESSAGE }, status: :service_unavailable
        end

        def update
          require_ssn_confirmation!(@employee) if params.dig(:employee, :ssn).present? && params.dig(:employee, :ssn).to_s.gsub(/\D/, "") != @employee.ssn_digits
          result = with_employee_audit(action: "client_employees#update") do
            ClientEmployeeUpdateService.new(
              employee: @employee,
              attrs: employee_params.to_h,
              requested_by: current_user,
              company: current_company,
              confirm_same_person_email: confirm_same_person_email_param,
              row_revision: row_revision_param,
              baseline_values: baseline_values_param
            ).update!
          end

          contact_context = EmployeeContactValidator.contact_details_context(company: current_company)
          render json: {
            data: serialize_employee(result.employee, contact_context: contact_context),
            change_request: serialize_change_request(result.change_request),
            applied_direct_fields: result.applied_direct_fields,
            contact_warnings: result.contact_warnings || [],
            message: result.change_request ?
              "Profile updates saved. Payroll-sensitive changes were submitted for approval as request ##{result.change_request.id}." :
              "Employee profile updated successfully."
          }
        rescue EmployeeContactRevisionGuard::ConflictError => e
          contact_context = EmployeeContactValidator.contact_details_context(company: current_company)
          render json: {
            error: e.message,
            code: "contact_revision_conflict",
            conflicting_fields: e.conflicting_fields,
            contact_revision: e.employee.contact_revision,
            current_values: e.current_values,
            data: serialize_employee(e.employee, contact_context: contact_context)
          }, status: :conflict
        rescue EmployeeContactValidator::ValidationError => e
          render json: {
            error: "Validation failed",
            details: e.record.errors.messages,
            contact_validation: e.result.contact_validation_payload
          }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            error: "Validation failed",
            details: e.record.errors.messages
          }, status: :unprocessable_entity
        rescue LegacyRecurringComponentGuard::Error => e
          render json: { error: "Validation failed", details: { payroll_components: [ e.message ] } }, status: :unprocessable_entity
        rescue AuditWriteFailed
          render json: { error: AUDIT_FAILURE_MESSAGE }, status: :service_unavailable
        end

        private

        # A practice copy can close (archived, sealed, expired) while its form is
        # still open; refuse the write rather than relying on the hidden button.
        def reject_closed_practice_copy
          return unless current_company&.test_workspace_read_only?

          render json: { error: "This practice copy is read-only. Your changes were not saved." }, status: :forbidden
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
            :name_suffix,
            :last_name,
            :job_title,
            :email,
            :ssn,
            :date_of_birth,
            :hire_date,
            :department_id,
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
            :w4_election_received,
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

            # The client only sees the EIN's last four, so a blank value means
            # "keep the stored EIN", exactly like a blank SSN.
            permitted.delete(:contractor_ein) if permitted.key?(:contractor_ein) && permitted[:contractor_ein].blank?
          end
        end

        def require_ssn_confirmation!(employee)
          employee.require_ssn_confirmation = true
          employee.ssn_confirmation = params.require(:employee).permit(:ssn_confirmation)[:ssn_confirmation]
        end

        def apply_filters(scope)
          scope = scope.intake_incomplete if params[:intake_status] == "incomplete"
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

        def serialize_employee(employee, include_department: false, include_document_readiness: false, contact_context: nil)
          data = employee.as_json(
            except: [ :intake_exception, :ssn_encrypted, :contractor_ein, :bank_account_number_encrypted, :bank_routing_number_encrypted ]
          )
          data["contact_revision"] = employee.contact_revision
          data["contact_details_status"] = EmployeeContactValidator.contact_details_status(employee, context: contact_context)
          data["intake_readiness"] = EmployeeIntakePolicy.summary(employee).merge(can_review: false)
          data["ssn_last_four"] = employee.ssn_last_four
          data["contractor_ein_last_four"] = employee.contractor_ein.to_s.gsub(/\D/, "").last(4).presence
          rates_on = PayrollBusinessClock.today
          data.merge!(EmployeeCompensationChangeService.snapshot(employee, rates_on).as_json)
          data["wage_rates"] = employee.wage_rates_on(rates_on).map do |rate|
            {
              id: rate.id,
              employee_id: rate.employee_id,
              label: rate.label,
              rate: rate.rate,
              is_primary: rate.is_primary,
              active: rate.active
            }
          end
          current_retirement = employee.retirement_election_on(PayrollBusinessClock.today)
          data["current_retirement_election"] = current_retirement&.as_json(except: [ :created_by_id ])

          if include_department && employee.department
            data["department"] = {
              id: employee.department.id,
              name: employee.department.name
            }
          end

          data["document_readiness"] = EmployeeDocumentReadiness.summary(employee) if include_document_readiness

          data
        end

        def serialize_change_request(change_request)
          return nil unless change_request

          {
            id: change_request.id,
            status: change_request.status,
            request_kind: change_request.request_kind,
            employee_id: change_request.employee_id,
            employee_name: change_request.employee.full_name,
            requested_by_id: change_request.requested_by_id,
            requested_by_name: change_request.requested_by&.name,
            proposed_changes: redact_change_request_payload(change_request.proposed_changes),
            original_values: redact_change_request_payload(change_request.original_values),
            direct_changes_applied: redact_change_request_payload(change_request.direct_changes_applied),
            request_notes: change_request.request_notes,
            created_at: change_request.created_at
          }
        end

        def redact_change_request_payload(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, nested_value), redacted|
              redacted[key] = if SENSITIVE_CHANGE_REQUEST_KEYS.include?(key.to_s)
                "[REDACTED]"
              else
                redact_change_request_payload(nested_value)
              end
            end
          when Array
            value.map { |nested_value| redact_change_request_payload(nested_value) }
          else
            value
          end
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

        def confirm_same_person_email_param
          raw = params.key?(:confirm_same_person_email) ? params[:confirm_same_person_email] : params.dig(:employee, :confirm_same_person_email)
          ActiveModel::Type::Boolean.new.cast(raw) == true
        end

        def row_revision_param
          params[:row_revision].presence ||
            params[:contact_revision].presence ||
            params[:expected_updated_at].presence ||
            params.dig(:employee, :row_revision).presence ||
            params.dig(:employee, :contact_revision).presence ||
            params.dig(:employee, :expected_updated_at).presence
        end

        def baseline_values_param
          raw = params[:baseline_values] || params.dig(:employee, :baseline_values)
          return nil unless raw.respond_to?(:permit)

          raw.permit(*ClientEmployeeUpdateService::DIRECT_FIELDS).to_h
        end

        def needs_contact_details_filter_active?
          ActiveModel::Type::Boolean.new.cast(params[:needs_contact_details]) == true ||
            params[:contact_status] == "needs_contact_details"
        end

        def audit_metadata_for(result)
          metadata = {
            source: "client_portal",
            employee_name: result.employee.display_name,
            changed_fields: result.changed_fields,
            applied_direct_fields: result.applied_direct_fields,
            approval_fields: result.approval_fields,
            change_request_id: result.change_request&.id,
            before_values: sanitized_audit_values(result.before_values),
            after_values: sanitized_audit_values(result.after_values)
          }
          if result.same_person_email_confirmed
            metadata[:same_person_email_confirmed] = true
            metadata[:confirmed_login_user_id] = result.confirmed_login_user_id
          end
          metadata
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

        # The employee change and its audit row commit together: if the audit
        # write fails, the change rolls back and the client sees an error.
        def with_employee_audit(action:)
          ActiveRecord::Base.transaction do
            result = yield
            record_employee_audit!(action: action, result: result)
            result
          end
        end

        def record_employee_audit!(action:, result:)
          AuditLog.record!(
            user: current_user,
            company_id: current_company_id,
            action: action,
            record_type: "employees",
            record_id: result.employee.id,
            subject_name: result.employee.full_name,
            metadata: audit_metadata_for(result),
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          )
        rescue StandardError => e
          Rails.logger.error("[ClientEmployeesController] Audit log failed; rolling back #{action}: #{e.class}")
          raise AuditWriteFailed, e.message
        end
      end
    end
  end
end
