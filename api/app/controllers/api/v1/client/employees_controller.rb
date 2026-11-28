# frozen_string_literal: true

module Api
  module V1
    module Client
      class EmployeesController < BaseController
        include EmployeeContactLoginRejectionGuard
        SENSITIVE_CHANGE_REQUEST_KEYS = %w[ssn ssn_encrypted contractor_ein sensitive_payload_encrypted].freeze
        CLIENT_VISIBLE_VERIFICATION_METADATA_KEYS = %w[
          readiness_status
          missing_keys
          direct_deposit_missing_bank_details
          final_pay_notes
          post_termination_committed_pay_period_ids
          client_response_note
        ].freeze
        DEFAULT_PER_PAGE = 25
        MAX_PER_PAGE = 500
        AUDIT_FAILURE_MESSAGE = "This change was not saved because its activity record could not be written. Please try again."

        class AuditWriteFailed < StandardError; end

        before_action :reject_closed_practice_copy, only: [ :create, :update, :terminate, :rehire ]
        before_action :set_employee, only: [ :show, :update, :terminate, :rehire ]

        def index
          if params[:rates_on].present?
            return unless authorize_and_resolve_rates_on!
          end
          client_managed = CompanyFeatures.for(current_company).client_managed_employee_lifecycle?
          contact_context = EmployeeContactValidator.contact_details_context(company: current_company)
          employees = Employee.where(company_id: current_company_id)
          if client_managed && params[:needs_attention] == "true"
            employees = employees.where(id: EmployeeVerificationItem.where(company_id: current_company_id, status: "returned_to_client").select(:employee_id))
          end
          employees = apply_filters(employees)
          needs_contact_details_count = employees.needs_contact_details(flagged_emails: contact_context[:flagged_emails]).count
          if needs_contact_details_filter_active?
            employees = employees.needs_contact_details(flagged_emails: contact_context[:flagged_emails])
          end
          employees = apply_sort(employees)
          employees = employees.includes(:department, :employee_wage_rates, :employee_w4_elections)
            .preload(:employee_wage_rate_versions, :employee_compensation_changes)
          employees = employees.page(params[:page]).per(bounded_per_page(default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE))

          page_employees = employees.to_a
          readiness_by_id = if EmployeeContactProjection.requested?(params)
            {}
          else
            readiness_targets = client_managed ? page_employees : page_employees.select(&:readiness_gate_enforced?)
            EmployeeReadinessEvaluator.evaluate_batch(readiness_targets, company: current_company, rates_on: @rates_on)
          end

          render json: {
            data: page_employees.map { |employee| contact_page_or_full(employee, contact_context, readiness: readiness_by_id[employee.id]) },
            meta: pagination_meta(employees).merge(needs_contact_details_count: needs_contact_details_count)
          }
        end

        def show
          contact_context = EmployeeContactValidator.contact_details_context(company: current_company)
          features = CompanyFeatures.for(current_company)
          client_managed = features.client_managed_employee_lifecycle?
          readiness = if client_managed || @employee.readiness_gate_enforced?
            EmployeeReadinessEvaluator.evaluate(@employee, rates_on: @rates_on)
          end
          data = serialize_employee(@employee, include_department: true, include_document_readiness: true, contact_context: contact_context, readiness: readiness)
          if client_managed && current_user.client? && !current_user.client_viewer?
            data["lifecycle_edit_context"] = lifecycle_edit_context(@employee, features, readiness)
          end
          render json: { data: data }
        end

        def create
          return unless ensure_scheduled_lifecycle_mode_attempted!

          employee = Employee.new
          require_ssn_confirmation!(employee)
          result = with_employee_audit(action: "client_employees#create") do
            ClientEmployeeUpdateService.new(
              employee: employee,
              attrs: employee_params.to_h,
              requested_by: current_user,
              company: current_company,
              confirm_same_person_email: confirm_same_person_email_param,
              email_locked: contact_email_submitted_in_request? && login_email_cooldown_active?,
              attempt_lifecycle_activation: false
            ).create!
          end

          contact_context = EmployeeContactValidator.contact_details_context(company: current_company)
          if result.client_managed
            render json: {
              data: serialize_employee(result.employee, contact_context: contact_context, readiness: result.readiness),
              change_request: nil,
              readiness: result.readiness&.as_json,
              verification_items: Array(result.verification_items).map { |item| serialize_verification_item(item) },
              applied_direct_fields: result.applied_direct_fields,
              contact_warnings: result.contact_warnings || [],
              warnings: result.warnings || [],
              message: create_client_managed_message(result)
            }, status: :created
          else
            readiness = result.employee.readiness_gate_enforced? ? EmployeeReadinessEvaluator.evaluate(result.employee) : nil
            render json: {
              data: serialize_employee(result.employee, contact_context: contact_context, readiness: readiness),
              change_request: serialize_change_request(result.change_request),
              applied_direct_fields: result.applied_direct_fields,
              contact_warnings: result.contact_warnings || [],
              message: "Employee profile created. Payroll-sensitive details were submitted for approval as request ##{result.change_request.id}."
            }, status: :created
          end
        rescue ClientOperatingProfiles::LifecycleModeActivationService::ModeChanged => e
          render_lifecycle_mode_changed!(e.message)
        rescue EmployeeContactValidator::ValidationError => e
          render_contact_validation_error!(e, employee: @employee || e.record)
        rescue EmployeeContactChanges::EmailChangeLocked
          render_login_email_cooldown!
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
          return unless ensure_scheduled_lifecycle_mode_attempted!

          require_ssn_confirmation!(@employee) if params.dig(:employee, :ssn).present? && params.dig(:employee, :ssn).to_s.gsub(/\D/, "") != @employee.ssn_digits
          result = with_employee_audit(action: "client_employees#update") do
            ClientEmployeeUpdateService.new(
              employee: @employee,
              attrs: employee_params.to_h,
              requested_by: current_user,
              company: current_company,
              confirm_same_person_email: confirm_same_person_email_param,
              row_revision: row_revision_param,
              baseline_values: baseline_values_param,
              email_locked: contact_email_submitted_in_request? && login_email_cooldown_active?,
              attempt_lifecycle_activation: false
            ).update!
          end

          contact_context = EmployeeContactValidator.contact_details_context(company: current_company)
          if result.client_managed
            render json: {
              data: contact_page_or_full(result.employee, contact_context, readiness: result.readiness),
              change_request: serialize_change_request(result.change_request),
              readiness: result.readiness&.as_json,
              verification_items: Array(result.verification_items).map { |item| serialize_verification_item(item) },
              applied_direct_fields: result.applied_direct_fields,
              contact_warnings: result.contact_warnings || [],
              warnings: result.warnings || [],
              message: update_client_managed_message(result)
            }
          else
            readiness = result.employee.readiness_gate_enforced? ? EmployeeReadinessEvaluator.evaluate(result.employee) : nil
            render json: {
              data: contact_page_or_full(result.employee, contact_context, readiness: readiness),
              change_request: serialize_change_request(result.change_request),
              applied_direct_fields: result.applied_direct_fields,
              contact_warnings: result.contact_warnings || [],
              message: update_message(result.change_request)
            }
          end
        rescue ClientOperatingProfiles::LifecycleModeActivationService::ModeChanged => e
          render_lifecycle_mode_changed!(e.message)
        rescue ClientEmployeeUpdateService::PendingAddressRequest => e
          render json: { error: e.message, code: "address_request_pending", pending_request_id: e.request_id },
            status: :conflict
        rescue EmployeeProfileIdentity::LinkCheckUnavailable => e
          render json: { error: e.message }, status: :service_unavailable
        rescue EmployeeContactRevisionGuard::ConflictError => e
          contact_context = EmployeeContactValidator.contact_details_context(company: current_company)
          render json: {
            error: e.message,
            code: "contact_revision_conflict",
            conflicting_fields: e.conflicting_fields,
            contact_revision: e.employee.contact_revision,
            current_values: e.current_values,
            data: contact_page_or_full(e.employee, contact_context)
          }, status: :conflict
        rescue EmployeeContactValidator::ValidationError => e
          render_contact_validation_error!(e, employee: @employee || e.record)
        rescue EmployeeContactChanges::EmailChangeLocked
          render_login_email_cooldown!
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

        def terminate
          return unless ensure_scheduled_lifecycle_mode_attempted!

          payload = termination_params
          reason_category = payload[:reason_category].to_s.strip
          unless EmployeeStatusEvent::TERMINATION_REASONS.include?(reason_category)
            return render json: {
              error: "Validation failed",
              details: { reason_category: [ "must be a valid termination reason" ] }
            }, status: :unprocessable_entity
          end

          final_pay_notes = payload[:final_pay_notes].to_s.strip.presence
          notes = payload[:notes].to_s.strip.presence
          if final_pay_notes && final_pay_notes.length > 2000
            return render json: {
              error: "Validation failed",
              details: { final_pay_notes: [ "is too long (maximum is 2000 characters)" ] }
            }, status: :unprocessable_entity
          end
          if notes && notes.length > 2000
            return render json: {
              error: "Validation failed",
              details: { notes: [ "is too long (maximum is 2000 characters)" ] }
            }, status: :unprocessable_entity
          end

          effective_date_input = payload[:effective_date].presence || payload[:last_worked_on].presence
          event = nil
          verification_item = nil
          post_termination_committed_ids = []
          warnings = []
          error_response = nil

          ActiveRecord::Base.transaction do
            Company.lock.find(current_company_id)
            revalidate_client_company_write_access!
            unless CompanyFeatures.for(current_company).client_managed_employee_lifecycle?
              error_response = [ {
                error: "Client-managed employee lifecycle is not enabled for this company.",
                code: "client_lifecycle_disabled"
              }, :forbidden ]
              next
            end

            if EmployeeProfileIdentity.own_record_for_client_managed?(@employee, current_user)
              error_response = [ {
                error: "You cannot terminate your own employee record.",
                code: "self_lifecycle_forbidden"
              }, :forbidden ]
              next
            end

            event = EmployeeStatusTransitionService.terminate!(
              employee: @employee,
              actor: current_user,
              attributes: {
                effective_date: effective_date_input,
                last_worked_on: payload[:last_worked_on].presence,
                reason_category: reason_category,
                internal_notes: notes,
                source: "client_portal"
              }
            )

            post_termination_committed_ids = post_termination_committed_pay_period_ids(@employee, event.effective_date)
            if post_termination_committed_ids.any?
              warnings << "This employee was already paid in committed payroll after #{event.effective_date.iso8601}. Cornerstone has been alerted to review for overpayment, void, or correction."
            end

            mid_period_approved = EmployeeStatusTransitionService.open_run_groups(@employee, effective_date: event.effective_date)
              .fetch(:check)
              .select(&:approved?)
            if mid_period_approved.any?
              warnings << "Terminating mid-period on an approved pay run requires Cornerstone to unapprove, recalculate, republish, and request re-approval before commit."
            end

            metadata = {
              "reason_category" => event.reason_category,
              "last_worked_on" => event.last_worked_on&.iso8601,
              "final_pay_notes" => final_pay_notes,
              "notes" => notes,
              "post_termination_committed_pay_period_ids" => post_termination_committed_ids
            }.compact

            verification_item = EmployeeVerificationItems::Recorder.record!(
              employee: @employee,
              actor: current_user,
              event_kind: "termination",
              changed_fields: %w[status termination_date],
              before_values: { "status" => event.previous_status, "termination_date" => nil },
              after_values: { "status" => "terminated", "termination_date" => event.effective_date.iso8601 },
              effective_on: event.effective_date,
              source_record: event,
              metadata: metadata
            )

            record_lifecycle_audit!(
              action: "client_employees#terminate",
              employee: @employee,
              metadata: {
                source: "client_portal",
                employee_name: @employee.display_name,
                status_event_id: event.id,
                verification_item_id: verification_item.id,
                effective_date: event.effective_date.iso8601,
                last_worked_on: event.last_worked_on&.iso8601,
                reason_category: event.reason_category,
                post_termination_committed_pay_period_ids: post_termination_committed_ids
              }.compact
            )
          end

          return render json: error_response[0], status: error_response[1] if error_response

          contact_context = EmployeeContactValidator.contact_details_context(company: current_company)
          reloaded = @employee.reload
          render json: {
            data: serialize_employee(reloaded, contact_context: contact_context, readiness: EmployeeReadinessEvaluator.evaluate(reloaded)),
            status_event: serialize_status_event(event),
            verification_item: serialize_verification_item(verification_item),
            post_termination_committed_pay_period_ids: post_termination_committed_ids,
            warnings: warnings,
            message: "#{@employee.full_name} has been terminated effective #{event.effective_date.iso8601}. Cornerstone has been notified to verify."
          }
        rescue EmployeeProfileIdentity::LinkCheckUnavailable => e
          render json: { error: e.message }, status: :service_unavailable
        rescue EmployeeStatusTransitionService::ApprovedRunBlocked => e
          run = e.pay_period
          render json: {
            error: "This employee is on an approved pay run for #{run.start_date.iso8601} to #{run.end_date.iso8601}. Ask Cornerstone to unapprove that run before terminating effective #{e.effective_date.iso8601}."
          }, status: :unprocessable_entity
        rescue EmployeeStatusTransitionService::Forbidden => e
          render json: { error: e.message }, status: :forbidden
        rescue EmployeeStatusTransitionService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
        rescue AuditWriteFailed
          render json: { error: AUDIT_FAILURE_MESSAGE }, status: :service_unavailable
        end

        def rehire
          return unless ensure_scheduled_lifecycle_mode_attempted!

          payload = rehire_params
          notes = payload[:notes].to_s.strip.presence
          if notes && notes.length > 2000
            return render json: {
              error: "Validation failed",
              details: { notes: [ "is too long (maximum is 2000 characters)" ] }
            }, status: :unprocessable_entity
          end

          event = nil
          readiness = nil
          verification_item = nil
          error_response = nil

          ActiveRecord::Base.transaction do
            Company.lock.find(current_company_id)
            revalidate_client_company_write_access!
            unless CompanyFeatures.for(current_company).client_managed_employee_lifecycle?
              error_response = [ {
                error: "Client-managed employee lifecycle is not enabled for this company.",
                code: "client_lifecycle_disabled"
              }, :forbidden ]
              next
            end

            if EmployeeProfileIdentity.own_record_for_client_managed?(@employee, current_user)
              error_response = [ {
                error: "You cannot rehire your own employee record.",
                code: "self_lifecycle_forbidden"
              }, :forbidden ]
              next
            end

            previous_termination_date = @employee.termination_date
            event = EmployeeStatusTransitionService.reactivate!(
              employee: @employee,
              actor: current_user,
              attributes: {
                effective_date: payload[:effective_date],
                internal_notes: notes,
                source: "client_portal"
              }
            )

            # Stamp readiness_gate_enforced = true on client-portal rehire while
            # keeping any existing document_readiness_required gate untouched (§3.2).
            @employee.update!(readiness_gate_enforced: true) unless @employee.readiness_gate_enforced?
            readiness = EmployeeReadinessEvaluator.evaluate(@employee.reload)

            verification_item = EmployeeVerificationItems::Recorder.record!(
              employee: @employee,
              actor: current_user,
              event_kind: "rehire",
              changed_fields: %w[status termination_date readiness_gate_enforced],
              before_values: {
                "status" => event.previous_status,
                "termination_date" => previous_termination_date&.iso8601
              },
              after_values: {
                "status" => "active",
                "termination_date" => nil
              },
              effective_on: event.effective_date,
              source_record: event,
              metadata: {
                "notes" => notes,
                "readiness_status" => readiness.status,
                "missing_keys" => readiness.missing_keys
              }.compact
            )

            record_lifecycle_audit!(
              action: "client_employees#rehire",
              employee: @employee,
              metadata: {
                source: "client_portal",
                employee_name: @employee.display_name,
                status_event_id: event.id,
                verification_item_id: verification_item.id,
                effective_date: event.effective_date.iso8601,
                readiness_status: readiness.status
              }.compact
            )
          end

          return render json: error_response[0], status: error_response[1] if error_response

          contact_context = EmployeeContactValidator.contact_details_context(company: current_company)
          render json: {
            data: serialize_employee(@employee.reload, contact_context: contact_context, readiness: readiness),
            status_event: serialize_status_event(event),
            readiness: readiness.as_json,
            verification_item: serialize_verification_item(verification_item),
            message: "#{@employee.full_name} has been rehired effective #{event.effective_date.iso8601}. Cornerstone has been notified to verify."
          }
        rescue EmployeeProfileIdentity::LinkCheckUnavailable => e
          render json: { error: e.message }, status: :service_unavailable
        rescue EmployeeStatusTransitionService::Forbidden => e
          render json: { error: e.message }, status: :forbidden
        rescue EmployeeStatusTransitionService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
        rescue AuditWriteFailed
          render json: { error: AUDIT_FAILURE_MESSAGE }, status: :service_unavailable
        end

        private

        def lifecycle_edit_context(employee, features, readiness)
          own_record = EmployeeProfileIdentity.own_record_for_client_managed?(employee, current_user)
          runs = EmployeeStatusTransitionService.open_runs(employee)
          {
            own_record: own_record,
            today: PayrollBusinessClock.today.iso8601,
            compensation_default_on: EmployeeCompensationChangeService.default_effective_on(employee).iso8601,
            calculated_through: runs.where(status: "calculated").maximum(:end_date)&.iso8601,
            calculated_pay_date: runs.where(status: "calculated").maximum(:pay_date)&.iso8601,
            approved_pay_date: runs.where(status: "approved").maximum(:pay_date)&.iso8601,
            approved_runs: runs.where(status: "approved").pluck(:start_date, :end_date).map do |start_date, end_date|
              { start_date: start_date.iso8601, end_date: end_date.iso8601 }
            end,
            last_committed_period_end: committed_regular_runs(employee).maximum(:end_date)&.iso8601,
            former_access_years: features.former_access_years,
            rehire_readiness: rehire_readiness(employee, readiness)
          }
        rescue EmployeeProfileIdentity::LinkCheckUnavailable
          # The profile remains readable. Writes still perform their own fail-closed check.
          nil
        end

        def rehire_readiness(employee, readiness)
          return unless employee.status == "terminated"

          EmployeeReadinessEvaluator.new(
            employee: employee, rates_on: readiness.rates_on, w4_on: readiness.w4_on, rehired: true
          ).evaluate.with(readiness_gate_enforced: true).as_json
        end

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
            :payment_delivery_method,
            :compensation_effective_on,
            :effective_on,
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

        # The Contact details page asks for contact fields only.
        def authorize_and_resolve_rates_on!
          if current_user.client_viewer?
            render json: { error: ClientPortalAccess::VIEW_ONLY, code: "client_view_only" }, status: :forbidden
            return false
          end
          unless current_company.portal_payroll_files_enabled?
            render json: { error: "Payroll submissions are not enabled for this company." }, status: :forbidden
            return false
          end

          parsed = parse_bounded_iso_date(params[:rates_on])
          unless parsed && submittable_period_end_date?(parsed)
            render json: { error: "rates_on must be the end date of an open payroll submission period (YYYY-MM-DD)" }, status: :unprocessable_entity
            return false
          end

          @rates_on = parsed
          true
        end

        def parse_bounded_iso_date(value)
          text = value.to_s.strip
          return nil unless text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          parsed = Date.iso8601(text)
          today = PayrollBusinessClock.today
          return nil unless parsed.between?(today - 10.years, today + 2.years)

          parsed
        rescue ArgumentError, Date::Error
          nil
        end

        def submittable_period_end_date?(date)
          catalog = PayrollSubmissions::Catalog.new(company: current_company)
          serializer = PayrollSubmissions::Serializer.new(current_user: current_user, catalog: catalog)
          catalog.entries.any? do |entry|
            entry.end_date == date && serializer.allowed_actions(entry).include?("submit")
          end
        end

        def contact_page_or_full(employee, contact_context, readiness: nil)
          return EmployeeContactProjection.call(employee, context: contact_context) if EmployeeContactProjection.requested?(params)

          serialize_employee(employee, contact_context: contact_context, readiness: readiness)
        end

        def serialize_employee(employee, include_department: false, include_document_readiness: false, contact_context: nil, readiness: nil)
          data = employee.as_json(
            except: [ :intake_exception, :ssn_encrypted, :contractor_ein, :bank_account_number_encrypted, :bank_routing_number_encrypted ]
          )
          data["contact_revision"] = employee.contact_revision
          data["contact_details_status"] = EmployeeContactValidator.contact_details_status(employee, context: contact_context)
          data["intake_readiness"] = EmployeeIntakePolicy.summary(employee).merge(can_review: false)
          data["ssn_last_four"] = employee.ssn_last_four
          data["contractor_ein_last_four"] = employee.contractor_ein.to_s.gsub(/\D/, "").last(4).presence
          rates_on = @rates_on || PayrollBusinessClock.today
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
          data["readiness"] = readiness.as_json if readiness

          data
        end

        # Run scheduled mode activation in its own committed transaction BEFORE
        # opening any client write transaction so a later write failure never
        # rolls back activation/blocker state, and an in-flight request never
        # silently changes semantics mid-request.
        def ensure_scheduled_lifecycle_mode_attempted!
          result = ClientOperatingProfiles::LifecycleModeActivationService.ensure_attempted!(current_company)
          return true unless result&.activated?

          render_lifecycle_mode_changed!(
            "This company switched to Client-managed employee lifecycle. Reload and submit your change again."
          )
          false
        end

        def render_lifecycle_mode_changed!(message)
          render json: {
            error: message,
            code: "lifecycle_mode_changed",
            employee_lifecycle_mode: "client_managed"
          }, status: :conflict
        end

        def create_client_managed_message(result)
          if result.readiness&.ready?
            "#{result.employee.full_name} is ready for payroll. Cornerstone will verify their details."
          else
            "#{result.employee.full_name} was saved as Incomplete. Finish the Ready to pay checklist to include them in payroll."
          end
        end

        def update_client_managed_message(result)
          if result.change_request
            return "Your address request was sent for review. Your current address stays on file until it’s approved." if result.change_request.profile_address?

            return "Changes to your own employee record were submitted to Cornerstone for review as request ##{result.change_request.id}."
          end

          "Saved. Cornerstone has been notified to verify this change."
        end

        def termination_params
          source = params[:termination].is_a?(ActionController::Parameters) ? params[:termination] : params
          source.permit(:effective_date, :last_worked_on, :reason_category, :final_pay_notes, :notes)
        end

        def rehire_params
          source = params[:rehire].is_a?(ActionController::Parameters) ? params[:rehire] : params
          source.permit(:effective_date, :notes)
        end

        def post_termination_committed_pay_period_ids(employee, effective_date)
          committed_regular_runs(employee).where("end_date > ?", effective_date).distinct.order(:id).pluck(:id)
        end

        def committed_regular_runs(employee)
          PayPeriod
            .where(company_id: current_company_id, status: "committed", run_purpose: "regular")
            .where("correction_status IS NULL OR correction_status <> ?", "voided")
            .joins(:payroll_items)
            .merge(PayrollItem.financially_reportable)
            .where(payroll_items: { employee_id: employee.id })
        end

        def serialize_status_event(event)
          {
            id: event.id,
            event_type: event.event_type,
            previous_status: event.previous_status,
            resulting_status: event.resulting_status,
            effective_date: event.effective_date&.iso8601,
            last_worked_on: event.last_worked_on&.iso8601,
            reason_category: event.reason_category,
            source: event.source
          }
        end

        def serialize_verification_item(item)
          return nil unless item

          {
            id: item.id,
            employee_id: item.employee_id,
            event_kind: item.event_kind,
            status: item.status,
            affects_pay: item.affects_pay,
            effective_on: item.effective_on&.iso8601,
            changed_fields: item.changed_fields,
            metadata: item.metadata.to_h.slice(*CLIENT_VISIBLE_VERIFICATION_METADATA_KEYS),
            created_at: item.created_at&.utc&.iso8601,
            updated_at: item.updated_at&.utc&.iso8601(6)
          }
        end

        def record_lifecycle_audit!(action:, employee:, metadata:)
          AuditLog.record!(
            user: current_user,
            company_id: current_company_id,
            action: action,
            record_type: "employees",
            record_id: employee.id,
            subject_name: employee.full_name,
            metadata: metadata,
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          )
        rescue StandardError => e
          Rails.logger.error("[ClientEmployeesController] Audit log failed; rolling back #{action}: #{e.class}")
          raise AuditWriteFailed, e.message
        end

        def update_message(change_request)
          return "Employee profile updated successfully." unless change_request
          return "Your address request was sent for review. Your current address stays on file until it’s approved." if change_request.profile_address?

          "Profile updates saved. Payroll-sensitive changes were submitted for approval as request ##{change_request.id}."
        end

        def serialize_change_request(change_request)
          return nil unless change_request

          {
            id: change_request.id,
            status: change_request.status,
            request_kind: change_request.request_kind,
            profile_address: change_request.profile_address?,
            note_visible_to_employee: change_request.requested_by_link_id.present?,
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
