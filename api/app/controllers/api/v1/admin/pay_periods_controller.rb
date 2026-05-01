# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayPeriodsController < BaseController
        include Auditable
        # `:corrective_paychecks` is the new off-cycle supplemental
        # endpoint — it mutates payroll state (creates a supplemental
        # period + a corrective payroll_item, mutates YTD), so it
        # belongs in the same AuditLog stream as commit/void/run_payroll.
        # Read-only previews (`:corrective_paycheck_preview`,
        # `:supplemental_pay_periods`) are deliberately omitted.
        audit_actions :approve, :unapprove, :commit, :run_payroll, :void,
                      :create_correction_run, :generate_fit_check,
                      :corrective_paychecks
        before_action :set_pay_period, only: [
          :show, :update, :destroy, :run_payroll, :approve, :unapprove, :commit, :retry_tax_sync,
          :void, :create_correction_run, :correction_history, :generate_fit_check,
          :corrective_paycheck_preview, :corrective_paychecks, :supplemental_pay_periods
        ]

        # GET /api/v1/admin/pay_periods
        def index
          @pay_periods = PayPeriod.where(company_id: current_company_id)
                                   .includes(:payroll_items, :voided_by, :correction_events,
                                             :supplemental_pay_periods)
                                   .period_chronological

          # Filter by status
          @pay_periods = @pay_periods.where(status: params[:status]) if params[:status].present?

          # Filter by year
          @pay_periods = @pay_periods.for_year(params[:year].to_i) if params[:year].present?

          loaded = @pay_periods.to_a
          preload_pay_period_audit_logs!(loaded)
          preload_pay_period_created_users!(loaded)
          render json: {
            pay_periods: loaded.map { |pp| pay_period_json(pp) },
            meta: {
              total: loaded.size,
              statuses: PayPeriod.where(company_id: current_company_id).group(:status).count
            }
          }
        end

        # GET /api/v1/admin/pay_periods/:id
        def show
          render json: {
            pay_period: pay_period_json(@pay_period, include_items: true)
          }
        end

        # POST /api/v1/admin/pay_periods
        def create
          @pay_period = PayPeriod.new(pay_period_params)
          @pay_period.company_id = current_company_id
          @pay_period.status = "draft"

          if @pay_period.save
            render json: { pay_period: pay_period_json(@pay_period) }, status: :created
          else
            render json: { errors: @pay_period.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH/PUT /api/v1/admin/pay_periods/:id
        def update
          unless @pay_period.can_edit?
            message = @pay_period.voided? ? "Cannot edit a voided pay period" : "Cannot edit a committed pay period"
            return render json: { error: message }, status: :unprocessable_entity
          end

          start_date_was = @pay_period.start_date
          end_date_was = @pay_period.end_date
          pay_date_was = @pay_period.pay_date

          begin
            @pay_period.transaction do
              @pay_period.update!(pay_period_params)
              dates_changed = start_date_was != @pay_period.start_date || end_date_was != @pay_period.end_date || pay_date_was != @pay_period.pay_date

              if dates_changed && !@pay_period.draft?
                @pay_period.update!(
                  status: "draft",
                  approved_by_id: nil,
                  approved_at: nil,
                  calculated_at: nil,
                  calculated_by_id: nil,
                  unapproved_at: nil,
                  unapproved_by_id: nil
                )
              end
            end

            render json: { pay_period: pay_period_json(@pay_period) }
          rescue ActiveRecord::RecordInvalid
            render json: { errors: @pay_period.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/v1/admin/pay_periods/:id
        def destroy
          if @pay_period.correction_run?
            unless @pay_period.draft?
              return render json: { error: "Can only delete draft correction run pay periods" }, status: :unprocessable_entity
            end

            # CPR-73: accept an operator-supplied reason for audit clarity
            deletion_reason = params[:reason].to_s.strip
            if deletion_reason.blank?
              deletion_reason = "Draft correction run deleted by operator"
            end

            begin
              if @pay_period.source_pay_period_id.blank?
                return render json: { error: "Cannot delete orphaned correction run without source linkage" }, status: :unprocessable_entity
              end

              deleted_run_id = @pay_period.id
              source_period  = nil
              source_period_id = nil
              correction_event = nil

              ActiveRecord::Base.transaction do
                locked_run = PayPeriod.lock("FOR UPDATE").find(@pay_period.id)
                unless locked_run.draft? && locked_run.correction_run?
                  locked_run.errors.add(:base, "Can only delete draft correction run pay periods")
                  raise ActiveRecord::RecordInvalid.new(locked_run)
                end

                source = PayPeriod.lock("FOR UPDATE").find(locked_run.source_pay_period_id)

                if locked_run.correction_events.exists?
                  locked_run.errors.add(:base, "Cannot delete correction run: audit events are attached to this run")
                  raise ActiveRecord::RecordInvalid.new(locked_run)
                end

                source.update!(superseded_by_id: nil) if source.superseded_by_id == locked_run.id

                correction_event = PayPeriodCorrectionEvent.record!(
                  action_type: "correction_run_deleted",
                  pay_period: source,
                  resulting_pay_period: nil,
                  actor: current_user,
                  reason: deletion_reason,
                  extra_metadata: {
                    deleted_correction_run_id: locked_run.id
                  }
                )

                locked_run.destroy!
                source_period_id = source.id
              end

              source_period = PayPeriod.includes(:payroll_items, :voided_by, :source_pay_period, :correction_events)
                                     .find(source_period_id)

              begin
                AuditLog.record!(
                  user:        current_user,
                  company_id:  current_company_id,
                  action:      "delete_draft_correction_run",
                  record_type: "PayPeriod",
                  record_id:   deleted_run_id,
                  metadata:    { reason: deletion_reason, source_pay_period_id: source_period.id },
                  ip_address:  request.remote_ip,
                  user_agent:  request.user_agent
                )
                skip_default_audit_log!
              rescue StandardError => e
                Rails.logger.error("[CPR-73] AuditLog delete_draft_correction_run failed for pay_period=#{deleted_run_id}: #{e.class}: #{e.message}")
              end

              return render json: {
                source_pay_period:         pay_period_json(source_period),
                deleted_correction_run_id: deleted_run_id,
                correction_event:          correction_event_json(correction_event)
              }, status: :ok
            rescue ActiveRecord::RecordInvalid => e
              return render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
            rescue ActiveRecord::RecordNotFound
              return render json: { error: "Source pay period not found" }, status: :unprocessable_entity
            rescue ActiveRecord::InvalidForeignKey, ActiveRecord::DeleteRestrictionError => e
              return render json: { error: e.message }, status: :unprocessable_entity
            end
          end

          if @pay_period.committed?
            return render json: { error: "Cannot delete a committed pay period" }, status: :unprocessable_entity
          end

          ActiveRecord::Base.transaction do
            PayrollImportRecord.where(pay_period_id: @pay_period.id).delete_all
            @pay_period.destroy!
          end
          head :no_content
        rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotDestroyed => e
          render json: { error: "Could not delete pay period: #{e.message}" }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/pay_periods/:id/run_payroll
        # Run payroll calculations for all employees in this pay period
        def run_payroll
          unless @pay_period.draft? || @pay_period.calculated?
            return render json: { error: "Can only run payroll on draft or calculated pay periods" }, status: :unprocessable_entity
          end

          # Determine which employees to calculate:
          # 1. If explicit employee_ids are passed, use those
          # 2. If imported payroll items exist, use imported employees + salary + contractors
          #    (don't auto-create hourly employees not present in the import)
          # 3. Otherwise, include all active employees for normal payroll runs/recalculations
          submitted_employee_ids = submitted_payroll_employee_ids
          employee_ids = if params[:employee_ids].present?
            Array(params[:employee_ids]) | submitted_employee_ids
          elsif @pay_period.payroll_items.where.not(import_source: [ nil, "" ]).exists?
            imported_ids = @pay_period.payroll_items.pluck(:employee_id)
            salary_ids = Employee.active.where(company_id: current_company_id, employment_type: "salary").pluck(:id)
            contractor_ids = Employee.active.where(company_id: current_company_id, employment_type: "contractor").pluck(:id)
            (imported_ids + salary_ids + contractor_ids + submitted_employee_ids).uniq
          else
            Employee.active.where(company_id: current_company_id).pluck(:id)
          end

          results = { success: [], errors: [] }

          employees_by_id = Employee.where(id: employee_ids, company_id: current_company_id)
                                     .active
                                     .includes(:employee_deductions, :deduction_types, :employee_loans, :employee_wage_rates, :employee_ytd_totals)
                                     .index_by(&:id)

          preload_ytd_caches!(employees_by_id.values, @pay_period)

          employee_ids.each do |employee_id|
            employee = employees_by_id[employee_id.to_i]
            next unless employee

            begin
              # Find or create payroll item for this employee
              payroll_item = @pay_period.payroll_items.find_or_initialize_by(employee_id: employee.id)

              # Set defaults from employee if new record
              if payroll_item.new_record?
                payroll_item.company_id = current_company_id
                payroll_item.employment_type = employee.employment_type
                payroll_item.hours_worked = 0
                payroll_item.additional_withholding = employee.additional_withholding.to_f
                payroll_item.custom_earnings = employee.default_custom_earnings
              end

              sync_pay_rate_from_employee(payroll_item, employee)

              # Use hours from params if provided
              if params[:hours] && params[:hours][employee_id.to_s]
                hours_data = params[:hours][employee_id.to_s]
                wage_rate_hours = hours_data[:wage_rates] || hours_data["wage_rates"]

                if wage_rate_hours.present?
                  apply_wage_rate_hours(payroll_item, wage_rate_hours, employee)
                else
                  payroll_item.clear_wage_rate_hours!
                  sync_pay_rate_from_employee(payroll_item, employee)
                  payroll_item.hours_worked = hours_data[:regular] if hours_data[:regular]
                  payroll_item.overtime_hours = hours_data[:overtime] if hours_data[:overtime]
                  payroll_item.holiday_hours = hours_data[:holiday] if hours_data[:holiday]
                  payroll_item.pto_hours = hours_data[:pto] if hours_data[:pto]
                end
              end

              # Apply salary override for variable-salary employees
              if params[:salary_overrides] && params[:salary_overrides][employee_id.to_s]
                override_val = params[:salary_overrides][employee_id.to_s].to_f
                payroll_item.salary_override = override_val > 0 ? override_val : nil
              end

              # Apply tips from the Adjust Hours table
              if params[:tips] && params[:tips][employee_id.to_s]
                tip_data = params[:tips][employee_id.to_s]
                tip_amount = (tip_data[:amount] || tip_data["amount"]).to_f
                tip_pool = (tip_data[:pool] || tip_data["pool"]).to_s.presence
                payroll_item.reported_tips = tip_amount > 0 ? tip_amount : 0
                payroll_item.tip_pool = tip_pool
              end

              if params[:tips_paid_out] && params[:tips_paid_out][employee_id.to_s]
                tips_paid_out_val = params[:tips_paid_out][employee_id.to_s].to_f
                payroll_item.tips_paid_out = tips_paid_out_val > 0 ? tips_paid_out_val : 0
              end

              # Apply loan deductions from the Adjust Hours table
              if params[:loan_deductions] && params[:loan_deductions][employee_id.to_s]
                loan_val = params[:loan_deductions][employee_id.to_s].to_f
                payroll_item.loan_deduction = loan_val > 0 ? loan_val : 0
              end

              if params[:custom_earnings] && params[:custom_earnings][employee_id.to_s]
                payroll_item.custom_earnings = normalize_custom_earnings(params[:custom_earnings][employee_id.to_s])
              end

              # Calculate payroll
              payroll_item.calculate!
              results[:success] << { employee_id: employee.id, name: employee.full_name }
            rescue StandardError => e
              results[:errors] << { employee_id: employee.id, error: e.message }
            end
          end

          # Update pay period status
          if results[:errors].empty?
            @pay_period.update!(
              status: "calculated",
              calculated_at: Time.current,
              calculated_by_id: current_user_id,
              approved_at: nil,
              approved_by_id: nil,
              unapproved_at: nil,
              unapproved_by_id: nil
            )
          end

          render json: {
            pay_period: pay_period_json(@pay_period, include_items: true),
            results: results
          }
        end

        # POST /api/v1/admin/pay_periods/:id/approve
        def approve
          unless @pay_period.calculated?
            return render json: { error: "Can only approve a calculated pay period" }, status: :unprocessable_entity
          end

          @pay_period.update!(
            status: "approved",
            approved_by_id: current_user_id,
            approved_at: Time.current
          )
          render json: { pay_period: pay_period_json(@pay_period) }
        end

        # POST /api/v1/admin/pay_periods/:id/unapprove
        # Roll back an approved pay period to calculated status.
        def unapprove
          unless @pay_period.approved?
            return render json: { error: "Can only unapprove an approved pay period" }, status: :unprocessable_entity
          end

          @pay_period.update!(
            status: "calculated",
            approved_by_id: nil,
            approved_at: nil,
            unapproved_at: Time.current,
            unapproved_by_id: current_user_id
          )
          render json: { pay_period: pay_period_json(@pay_period) }
        end

        # POST /api/v1/admin/pay_periods/:id/commit
        # Final lock - no more changes allowed
        def commit
          unless @pay_period.approved?
            return render json: { error: "Can only commit an approved pay period" }, status: :unprocessable_entity
          end

          unless @pay_period.payroll_items.exists?
            return render json: { error: "Cannot commit pay period with no payroll items" }, status: :unprocessable_entity
          end

          ActiveRecord::Base.transaction do
            @pay_period.update!(
              status: "committed",
              committed_at: Time.current,
              committed_by_id: current_user_id
            )
            committed_items = @pay_period.payroll_items.includes(
              :employee,
              payroll_item_deductions: :deduction_type,
              employee: { employee_loans: :loan_transactions }
            ).to_a

            # Preload YTD records to avoid N find_or_create_by calls per item
            year = @pay_period.pay_date.year
            employee_ids = committed_items.map(&:employee_id).uniq

            emp_ytds = EmployeeYtdTotal.where(employee_id: employee_ids, year: year).index_by(&:employee_id)
            employee_ids.each do |eid|
              emp_ytds[eid] ||= EmployeeYtdTotal.find_or_create_by!(employee_id: eid, year: year)
            end

            co_ytd = CompanyYtdTotal.find_or_create_by!(company_id: @pay_period.company_id, year: year)

            committed_items.each do |item|
              PayrollCalculator.for(item.employee, item).apply_loan_payments!
              emp_ytds[item.employee_id].add_payroll_item!(item)
              co_ytd.add_payroll_item!(item)
            end

            # Auto-assign check numbers to payroll items with positive net pay.
            # $0 net pay items don't get checks. Uses company-level row lock to prevent collisions.
            unassigned = committed_items.select { |i| i.check_number.nil? && i.net_pay.to_d > 0 }
            @pay_period.company.assign_check_numbers!(unassigned) if unassigned.any?

            # Auto-create FIT tax deposit check if company setting is enabled
            if @pay_period.company.auto_create_fit_check?
              create_fit_tax_deposit_check!(committed_items)
            end

            # Prepare tax sync with a fresh idempotency key for this commit event.
            @pay_period.prepare_tax_sync!

            # CPR-71: if this is a correction run, write committed audit event atomically
            if @pay_period.correction_run?
              PayPeriodCorrectionService.record_correction_committed!(
                pay_period: @pay_period,
                actor:      current_user
              )
            end

            ActiveRecord.after_all_transactions_commit do
              PayrollTaxSyncJob.perform_later(@pay_period.id)
            end
          end

          render json: { pay_period: pay_period_json(@pay_period) }
        rescue PayPeriodCorrectionService::CorrectionError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # ----------------------------------------------------------------
        # CPR-71: Payroll Correction Workflow
        # ----------------------------------------------------------------

        # POST /api/v1/admin/pay_periods/:id/void
        #
        # Voids a committed pay period. Reverses YTD totals and writes an
        # immutable correction audit event. Requires a mandatory reason.
        def void
          reason = params[:reason].to_s.strip
          if reason.blank?
            return render json: { error: "A reason is required to void a pay period" }, status: :unprocessable_entity
          end

          begin
            event = PayPeriodCorrectionService.void!(
              pay_period: @pay_period,
              actor:      current_user,
              reason:     reason
            )

            begin
              AuditLog.record!(
                user:        current_user,
                company_id:  current_company_id,
                action:      "void_pay_period",
                record_type: "PayPeriod",
                record_id:   @pay_period.id,
                metadata:    { reason: reason, voided_at: event.created_at },
                ip_address:  request.remote_ip,
                user_agent:  request.user_agent
              )
              skip_default_audit_log!
            rescue StandardError => e
              Rails.logger.error("[CPR-71] AuditLog void_pay_period failed for pay_period=#{@pay_period.id}: #{e.class}: #{e.message}")
            end

            @pay_period.reload
            render json: {
              pay_period: pay_period_json(@pay_period),
              correction_event: correction_event_json(event)
            }
          rescue PayPeriodCorrectionService::CorrectionError => e
            render json: { error: e.message }, status: :unprocessable_entity
          rescue ActiveRecord::RecordInvalid => e
            render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
          rescue ArgumentError => e
            render json: { error: e.message }, status: :unprocessable_entity
          end
        end

        # POST /api/v1/admin/pay_periods/:id/create_correction_run
        #
        # Creates a new draft pay period that corrects a voided period.
        # The source period must be voided and not already superseded.
        # The new period copies employee list from source for easy adjustment.
        def create_correction_run
          reason = params[:reason].to_s.strip
          if reason.blank?
            return render json: { error: "A reason is required to create a correction run" }, status: :unprocessable_entity
          end

          begin
            new_start_date = parse_iso_date_param(params[:start_date])
            new_end_date   = parse_iso_date_param(params[:end_date])
            new_pay_date   = parse_iso_date_param(params[:pay_date])

            correction_run = PayPeriodCorrectionService.create_correction_run!(
              source_pay_period: @pay_period,
              actor:             current_user,
              reason:            reason,
              new_start_date:    new_start_date,
              new_end_date:      new_end_date,
              new_pay_date:      new_pay_date,
              notes:             params[:notes]
            )

            begin
              AuditLog.record!(
                user:        current_user,
                company_id:  current_company_id,
                action:      "create_correction_run",
                record_type: "PayPeriod",
                record_id:   @pay_period.id,
                metadata:    { reason: reason, correction_run_id: correction_run.id },
                ip_address:  request.remote_ip,
                user_agent:  request.user_agent
              )
              skip_default_audit_log!
            rescue StandardError => e
              Rails.logger.error("[CPR-71] AuditLog create_correction_run failed for pay_period=#{@pay_period.id}: #{e.class}: #{e.message}")
            end

            @pay_period.reload
            render json: {
              source_pay_period: pay_period_json(@pay_period),
              correction_run:    pay_period_json(correction_run)
            }, status: :created
          rescue PayPeriodCorrectionService::NotVoidedError => e
            render json: { error: e.message }, status: :unprocessable_entity
          rescue PayPeriodCorrectionService::AlreadySupersededError => e
            render json: { error: e.message }, status: :unprocessable_entity
          rescue PayPeriodCorrectionService::CorrectionError => e
            render json: { error: e.message }, status: :unprocessable_entity
          rescue ActiveRecord::RecordInvalid => e
            render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
          rescue ArgumentError => e
            render json: { error: "Invalid date: #{e.message}" }, status: :unprocessable_entity
          end
        end

        # GET /api/v1/admin/pay_periods/:id/correction_history
        #
        # Returns the full correction audit trail for a pay period:
        # events where it is the source and events where it is the result.
        def correction_history
          events = PayPeriodCorrectionService.audit_trail(@pay_period)

          render json: {
            pay_period:        pay_period_correction_summary_json(@pay_period),
            correction_events: events.map { |e| correction_event_json(e) }
          }
        end

        # ----------------------------------------------------------------
        # Per-employee corrective paycheck (off-cycle supplemental period)
        # ----------------------------------------------------------------

        # POST /api/v1/admin/pay_periods/:id/corrective_paycheck_preview
        # Body: { employee_id, corrected_inputs: {...} }
        # Returns the original snapshot, recomputed corrected snapshot,
        # and per-field deltas — without persisting anything.
        def corrective_paycheck_preview
          employee = current_company.employees.find_by(id: params[:employee_id])
          unless employee
            return render json: { error: "Employee not found in this company" }, status: :not_found
          end

          preview = IssueCorrectivePaycheckService.preview(
            original_pay_period: @pay_period,
            employee:            employee,
            corrected_inputs:    permit_corrective_paycheck_inputs
          )

          render json: preview
        rescue IssueCorrectivePaycheckService::CorrectionError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/pay_periods/:id/corrective_paychecks
        # Body: { employee_id, corrected_inputs: {...}, pay_date, reason, notes }
        # Creates and commits a supplemental pay_period containing one
        # corrective payroll_item linked to the original. Returns the
        # supplemental pay_period and the corrective item.
        def corrective_paychecks
          employee = current_company.employees.find_by(id: params[:employee_id])
          unless employee
            return render json: { error: "Employee not found in this company" }, status: :not_found
          end

          supplemental, corrective_item = IssueCorrectivePaycheckService.issue!(
            original_pay_period: @pay_period,
            employee:            employee,
            corrected_inputs:    permit_corrective_paycheck_inputs,
            pay_date:            params[:pay_date],
            reason:              params[:reason],
            actor:               current_user,
            notes:               params[:notes]
          )

          render json: {
            supplemental_pay_period: pay_period_json(supplemental, include_items: true),
            corrective_payroll_item: payroll_item_summary_json(corrective_item),
            original_pay_period_id:  @pay_period.id
          }, status: :created
        rescue IssueCorrectivePaycheckService::CorrectionError, ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/pay_periods/:id/supplemental_pay_periods
        # Lists supplemental periods that correct this period (and a one-line
        # summary of each — handy for the "Linked Corrections" UI section).
        def supplemental_pay_periods
          unless @pay_period.regular_cycle?
            return render json: { error: "Only regular pay periods have supplementals" }, status: :unprocessable_entity
          end

          # Eager-load `payroll_items: :employee` so `supplemental_summary_json`
          # can call `item.employee_full_name` without firing one
          # `SELECT employees.*` query per payroll_item (N+1).
          supplementals = @pay_period.supplemental_pay_periods
                                      .includes(payroll_items: :employee)
          render json: {
            supplemental_pay_periods: supplementals.map { |sp| supplemental_summary_json(sp) }
          }
        end

        # POST /api/v1/admin/pay_periods/:id/generate_fit_check
        def generate_fit_check
          unless @pay_period.status == "committed"
            return render json: { error: "FIT check can only be generated for committed pay periods" }, status: :unprocessable_entity
          end

          fit_query = {
            pay_period: @pay_period,
            company_id: @pay_period.company_id,
            auto_generated_type: NonEmployeeCheck::AUTO_GENERATED_TYPES[:fit_deposit],
            voided: false
          }

          existing = NonEmployeeCheck.find_by(fit_query)
          if existing
            return render json: { message: "FIT tax deposit check already exists", check_id: existing.id, created: false }
          end

          committed_items = @pay_period.payroll_items.where(voided: false).to_a
          create_fit_tax_deposit_check!(committed_items)

          fit_check = NonEmployeeCheck.find_by(fit_query)
          if fit_check
            render json: { message: "FIT tax deposit check created", check_id: fit_check.id, created: true }
          else
            render json: { error: "No FIT withholding to create a check for (total is $0)" }, status: :unprocessable_entity
          end
        end

        # POST /api/v1/admin/pay_periods/:id/retry_tax_sync
        def retry_tax_sync
          unless @pay_period.can_retry_sync?
            return render json: { error: "Tax sync cannot be retried for this pay period" }, status: :unprocessable_entity
          end

          @pay_period.update!(tax_sync_status: "pending", tax_sync_last_error: nil)
          PayrollTaxSyncJob.perform_later(@pay_period.id)

          render json: { pay_period: pay_period_json(@pay_period) }
        end

        private

        # Strong-params extraction for the corrective-paycheck endpoints'
        # `corrected_inputs` payload.
        #
        # Functionally, the service layer already does
        # `(corrected_inputs || {}).symbolize_keys.slice(*CORRECTABLE_INPUT_FIELDS)`
        # — so `to_unsafe_h` here was *safe*, but it bypassed the
        # strong-params discipline the rest of the API follows and
        # tripped Greptile's "unfiltered params" signal.
        #
        # This helper expresses the contract at the controller boundary:
        # scalar correctable fields are explicitly permitted; the
        # `custom_earnings` array is permitted with its known shape
        # (`[{label, amount}, ...]`); and `custom_columns_data` — a
        # JSONB hash whose top-level keys are operator-configured per
        # company and whose values may themselves be nested (e.g.
        # `wage_rate_hours: [...]`) — is read via `to_unsafe_h` *only*
        # after the parent permit call has already narrowed the surface.
        # Anything outside the allow-list is dropped at this layer.
        def permit_corrective_paycheck_inputs
          raw = params[:corrected_inputs]
          return {} if raw.blank?

          raw = ActionController::Parameters.new(raw) unless raw.is_a?(ActionController::Parameters)

          scalar_fields = IssueCorrectivePaycheckService::CORRECTABLE_INPUT_FIELDS -
                          %i[custom_earnings custom_columns_data]

          permitted = raw.permit(
            *scalar_fields,
            custom_earnings: [ :label, :amount ]
          ).to_h

          if raw[:custom_columns_data].present?
            nested = raw[:custom_columns_data]
            permitted["custom_columns_data"] = nested.is_a?(ActionController::Parameters) ?
              nested.to_unsafe_h : nested
          end

          permitted
        end

        def create_fit_tax_deposit_check!(items)
          return if NonEmployeeCheck.exists?(
            pay_period: @pay_period,
            company_id: @pay_period.company_id,
            auto_generated_type: NonEmployeeCheck::AUTO_GENERATED_TYPES[:fit_deposit],
            voided: false
          )

          w2_items = items.select { |i| i.employment_type != "contractor" && !i.voided? }
          total_fit = w2_items.sum { |i| i.withholding_tax.to_d }
          return if total_fit <= 0

          NonEmployeeCheck.create!(
            pay_period: @pay_period,
            company_id: @pay_period.company_id,
            payable_to: "Treasurer of Guam",
            amount: total_fit,
            check_type: "tax_deposit",
            auto_generated_type: NonEmployeeCheck::AUTO_GENERATED_TYPES[:fit_deposit],
            payment_period_type: "pay_period",
            payment_date: @pay_period.pay_date,
            memo: "FIT Withholding · PPE #{@pay_period.end_date.strftime('%m/%d/%Y')} · Form 500",
            description: "Auto-generated Federal Income Tax deposit (remit to Guam DRT via Form 500)",
            created_by: current_user
          )
        rescue ActiveRecord::RecordNotUnique
          # Concurrent request already created the check — safe to ignore
        end

        def pay_period_aggregates(pay_period)
          items = pay_period.payroll_items
          if items.loaded?
            arr = items.to_a
            {
              count: arr.size,
              gross: arr.sum { |i| i.gross_pay.to_f },
              net: arr.sum { |i| i.net_pay.to_f },
              employer_ss: arr.sum { |i| i.employer_social_security_tax.to_f },
              employer_medicare: arr.sum { |i| i.employer_medicare_tax.to_f }
            }
          else
            row = items.pick(
              Arel.sql("COUNT(*)"),
              Arel.sql("COALESCE(SUM(gross_pay), 0)"),
              Arel.sql("COALESCE(SUM(net_pay), 0)"),
              Arel.sql("COALESCE(SUM(employer_social_security_tax), 0)"),
              Arel.sql("COALESCE(SUM(employer_medicare_tax), 0)")
            )
            {
              count: row[0].to_i,
              gross: row[1].to_f,
              net: row[2].to_f,
              employer_ss: row[3].to_f,
              employer_medicare: row[4].to_f
            }
          end
        end

        def set_pay_period
          # `:supplemental_pay_periods` is eager-loaded so that
          # `pay_period_json` can call `pay_period.supplemental_pay_periods.size`
          # for the `supplemental_pay_periods_count` field without firing an
          # extra `SELECT COUNT(*)` query on every show/update/etc. request.
          @pay_period = PayPeriod
            .includes(:payroll_items, :voided_by, :source_pay_period,
                      :correction_events, :supplemental_pay_periods)
            .find(params[:id])

          unless @pay_period.company_id == current_company_id
            render json: { error: "Pay period not found" }, status: :not_found
          end
        end

        def pay_period_params
          params.require(:pay_period).permit(:start_date, :end_date, :pay_date, :notes)
        end

        def pay_period_json(pay_period, include_items: false)
          agg = pay_period_aggregates(pay_period)
          lifecycle = pay_period_lifecycle_summary(pay_period)

          json = {
            id: pay_period.id,
            company_id: pay_period.company_id,
            start_date: pay_period.start_date,
            end_date: pay_period.end_date,
            pay_date: pay_period.pay_date,
            status: pay_period.status,
            notes: pay_period.notes,
            period_description: pay_period.period_description,
            employee_count: agg[:count],
            total_gross: agg[:gross],
            total_net: agg[:net],
            total_employer_ss: agg[:employer_ss],
            total_employer_medicare: agg[:employer_medicare],
            calculated_at: pay_period.calculated_at,
            calculated_by_id: pay_period.calculated_by_id,
            approved_at: pay_period.approved_at,
            committed_at: pay_period.committed_at,
            committed_by_id: pay_period.committed_by_id,
            processed_at: pay_period.committed_at,
            processed_by_name: lifecycle.dig(:committed, :actor_name),
            tax_sync_status: pay_period.tax_sync_status,
            tax_sync_attempts: pay_period.tax_sync_attempts,
            tax_sync_last_error: pay_period.tax_sync_last_error,
            tax_synced_at: pay_period.tax_synced_at,
            lifecycle: lifecycle,
            # CPR-71: correction fields
            correction_status:        pay_period.correction_status,
            voided_at:                pay_period.voided_at,
            voided_by_id:             pay_period.voided_by_id,
            voided_by_name:           pay_period.voided_by&.name,
            void_reason:              pay_period.void_reason,
            source_pay_period_id:     pay_period.source_pay_period_id,
            superseded_by_id:         pay_period.superseded_by_id,
            can_void:                        pay_period.can_void?,
            can_create_correction_run:       pay_period.can_create_correction_run?,
            can_delete_draft_correction_run: pay_period.can_delete_draft_correction_run?,
            # Per-employee corrective paycheck (off-cycle supplemental period)
            cycle:                              pay_period.cycle,
            corrects_pay_period_id:             pay_period.corrects_pay_period_id,
            can_issue_corrective_paycheck:      pay_period.can_issue_corrective_paycheck?,
            supplemental_pay_periods_count:     (pay_period.regular_cycle? ? pay_period.supplemental_pay_periods.size : 0),
            created_at: pay_period.created_at,
            updated_at: pay_period.updated_at
          }

          if include_items
            json[:payroll_items] = pay_period.payroll_items.includes(employee: :department).map do |item|
              payroll_item_json(item)
            end
          end

          json
        end

        def payroll_item_json(item)
          {
            id: item.id,
            employee_id: item.employee_id,
            employee_first_name: item.employee&.first_name,
            employee_last_name: item.employee&.last_name,
            employee_name: item.employee_full_name,
            employment_type: item.employment_type,
            pay_rate: item.pay_rate,
            salary_override: item.salary_override,
            non_taxable_pay: item.non_taxable_pay,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            holiday_hours: item.holiday_hours,
            pto_hours: item.pto_hours,
            bonus: item.bonus,
            reported_tips: item.reported_tips,
            tips_paid_out: item.tips_paid_out,
            additional_withholding: item.additional_withholding,
            additional_withholding_override: item.additional_withholding_override,
            withholding_tax_adjustment: item.withholding_tax_adjustment,
            withholding_tax_override: item.withholding_tax_override,
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            state_withheld: payroll_item_state_withheld(item),
            retirement_payment: item.retirement_payment,
            roth_retirement_payment: item.roth_retirement_payment,
            loan_payment: item.loan_payment,
            insurance_payment: item.insurance_payment,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            employer_social_security_tax: item.employer_social_security_tax,
            employer_medicare_tax: item.employer_medicare_tax,
            employer_retirement_match: item.employer_retirement_match,
            employer_roth_retirement_match: item.employer_roth_retirement_match,
            department_id: item.employee&.department_id,
            department_name: item.employee&.department&.name,
            custom_earnings: item.custom_earnings || [],
            check_number: item.check_number,
            check_printed_at: item.check_printed_at,
            check_print_count: item.check_print_count,
            check_status: item.check_status,
            loan_deduction: item.loan_deduction,
            tip_pool: item.tip_pool,
            import_source: item.import_source,
            voided: item.voided,
            voided_at: item.voided_at,
            void_reason: item.void_reason,
            reprint_of_check_number: item.reprint_of_check_number,
            ytd_gross: item.ytd_gross,
            ytd_net: item.ytd_net,
            wage_rate_hours: item.wage_rate_hours
          }
        end

        def payroll_item_state_withheld(item)
          return item.state_withheld if item.respond_to?(:state_withheld)

          item.custom_columns_data.is_a?(Hash) ? item.custom_columns_data["state_withheld"] : nil
        end

        def submitted_payroll_employee_ids
          keyed_ids = %i[salary_overrides tips tips_paid_out loan_deductions custom_earnings].flat_map do |key|
            params[key].respond_to?(:keys) ? params[key].keys : []
          end

          hours_params = if params[:hours].respond_to?(:to_unsafe_h)
            params[:hours].to_unsafe_h
          elsif params[:hours].respond_to?(:to_h)
            params[:hours].to_h
          else
            {}
          end

          hours_ids = if hours_params.respond_to?(:each)
            hours_params.each_with_object([]) do |(employee_id, entry), ids|
              data = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry.to_h
              wage_rates = data[:wage_rates] || data["wage_rates"]
              has_wage_rate_hours = Array(wage_rates).any? do |rate|
                %w[regular_hours overtime_hours holiday_hours pto_hours].any? { |field| rate[field].to_f.positive? }
              end
              has_basic_hours = %w[regular overtime holiday pto].any? { |field| data[field].to_f.positive? }
              ids << employee_id if has_wage_rate_hours || has_basic_hours
            end
          else
            []
          end

          (keyed_ids + hours_ids).map(&:to_i).select(&:positive?).uniq
        end

        def normalize_custom_earnings(entries)
          Array(entries).filter_map do |entry|
            data = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry.to_h
            label = data["label"].to_s.strip
            amount = BigDecimal(data["amount"].to_s)
            next if label.blank? || amount <= 0 || !amount.finite?

            { "label" => label, "amount" => amount.round(2).to_f }
          rescue ArgumentError, FloatDomainError
            nil
          end
        end

        def apply_wage_rate_hours(payroll_item, wage_rate_hours, employee)
          payroll_item.wage_rate_hours = wage_rate_hours
          entries = payroll_item.wage_rate_hours

          payroll_item.hours_worked = entries.sum { |entry| entry["regular_hours"].to_f }
          payroll_item.overtime_hours = entries.sum { |entry| entry["overtime_hours"].to_f }
          payroll_item.holiday_hours = entries.sum { |entry| entry["holiday_hours"].to_f }
          payroll_item.pto_hours = entries.sum { |entry| entry["pto_hours"].to_f }

          primary_entry = entries.find { |entry| entry["is_primary"] } || entries.first
          payroll_item.pay_rate = primary_entry ? primary_entry["rate"].to_f : employee.pay_rate
        end

        def sync_pay_rate_from_employee(payroll_item, employee)
          return if payroll_item.wage_rate_hours.present?

          payroll_item.pay_rate = employee.primary_wage_rate&.rate || employee.pay_rate
        end

        # Compact summary of a corrective payroll_item — shipped back to the
        # frontend after issuing a correction so the UI can show the new
        # check number / net amount immediately.
        def payroll_item_summary_json(item)
          {
            id:                              item.id,
            employee_id:                     item.employee_id,
            employee_name:                   item.employee_full_name,
            pay_period_id:                   item.pay_period_id,
            correction_for_payroll_item_id:  item.correction_for_payroll_item_id,
            correction_reason:               item.correction_reason,
            gross_pay:                       item.gross_pay,
            withholding_tax:                 item.withholding_tax,
            social_security_tax:             item.social_security_tax,
            medicare_tax:                    item.medicare_tax,
            employer_social_security_tax:    item.employer_social_security_tax,
            employer_medicare_tax:           item.employer_medicare_tax,
            net_pay:                         item.net_pay,
            check_number:                    item.check_number,
            check_status:                    item.check_status
          }
        end

        # Compact summary of a supplemental pay period for the
        # "Linked Corrections" UI section on the original period's page.
        def supplemental_summary_json(supplemental)
          items = supplemental.payroll_items
          {
            id:                supplemental.id,
            pay_date:          supplemental.pay_date,
            committed_at:      supplemental.committed_at,
            status:            supplemental.status,
            cycle:             supplemental.cycle,
            notes:             supplemental.notes,
            tax_sync_status:   supplemental.tax_sync_status,
            payroll_items: items.map do |item|
              {
                id:                              item.id,
                employee_id:                     item.employee_id,
                employee_name:                   item.employee_full_name,
                correction_for_payroll_item_id:  item.correction_for_payroll_item_id,
                correction_reason:               item.correction_reason,
                gross_pay:                       item.gross_pay,
                withholding_tax:                 item.withholding_tax,
                social_security_tax:             item.social_security_tax,
                medicare_tax:                    item.medicare_tax,
                net_pay:                         item.net_pay,
                check_number:                    item.check_number,
                check_status:                    item.check_status
              }
            end,
            totals: {
              gross_delta: items.sum { |i| i.gross_pay.to_f },
              fit_delta:   items.sum { |i| i.withholding_tax.to_f },
              ss_delta:    items.sum { |i| i.social_security_tax.to_f },
              med_delta:   items.sum { |i| i.medicare_tax.to_f },
              net_delta:   items.sum { |i| i.net_pay.to_f }
            }
          }
        end

        def preload_pay_period_audit_logs!(pay_periods)
          @pay_period_audit_logs_by_record_id =
            if pay_periods.empty?
              {}
            else
              AuditLog
                .where(
                  company_id: current_company_id,
                  record_type: "pay_periods",
                  record_id: pay_periods.map(&:id)
                )
                .includes(:user)
                .order(:created_at)
                .group_by { |log| log.record_id.to_i }
            end
        end

        def preload_pay_period_created_users!(pay_periods)
          user_ids = pay_periods.filter_map(&:created_by_id).uniq
          @pay_period_created_user_names_by_id = visible_user_names_for_pay_periods(user_ids)
        end

        def pay_period_audit_logs(pay_period)
          @pay_period_audit_logs_by_record_id ||= {}
          @pay_period_audit_logs_by_record_id.fetch(pay_period.id) do
            @pay_period_audit_logs_by_record_id[pay_period.id] =
              AuditLog
                .where(
                  company_id: pay_period.company_id,
                  record_type: "pay_periods",
                  record_id: pay_period.id
                )
                .includes(:user)
                .order(:created_at)
                .to_a
          end
        end

        def pay_period_lifecycle_summary(pay_period)
          logs = pay_period_audit_logs(pay_period)

          {
            created: lifecycle_event_json(
              timestamp: pay_period.created_at,
              actor_name: historical_user_name(pay_period.created_by_id)
            ),
            calculated: lifecycle_event_from_saved_or_log(
              pay_period,
              logs,
              "pay_periods#run_payroll",
              timestamp: pay_period.calculated_at,
              user_id: pay_period.calculated_by_id
            ),
            approved: lifecycle_event_from_saved_or_log(
              pay_period,
              logs,
              "pay_periods#approve",
              timestamp: pay_period.approved_at,
              user_id: pay_period.approved_by_id
            ),
            unapproved: lifecycle_event_from_saved_or_log(
              pay_period,
              logs,
              "pay_periods#unapprove",
              timestamp: pay_period.unapproved_at,
              user_id: pay_period.unapproved_by_id
            ),
            committed: lifecycle_event_from_saved_or_log(
              pay_period,
              logs,
              "pay_periods#commit",
              timestamp: pay_period.committed_at,
              user_id: pay_period.committed_by_id
            ),
            tax_synced: lifecycle_event_json(timestamp: pay_period.tax_synced_at)
          }
        end

        def lifecycle_event_from_log(logs, action, fallback_timestamp: nil)
          log = logs.select { |entry| entry.action == action }.last
          return lifecycle_event_json(timestamp: fallback_timestamp) unless log

          lifecycle_event_json(
            timestamp: log.created_at,
            actor_name: log.user&.name
          )
        end

        def lifecycle_event_from_saved_or_log(pay_period, logs, action, timestamp:, user_id: nil)
          log_event = lifecycle_event_from_log(logs, action)
          event = lifecycle_event_json(
            timestamp: timestamp,
            actor_name: historical_user_name(user_id) || log_event[:actor_name]
          )
          return event if timestamp.present?

          log_event
        end

        def lifecycle_event_json(timestamp:, actor_name: nil)
          {
            timestamp: timestamp,
            actor_name: actor_name
          }
        end

        def historical_user_name(user_id)
          return nil if user_id.blank?

          @pay_period_created_user_names_by_id ||= {}
          @pay_period_created_user_names_by_id.fetch(user_id) do
            @pay_period_created_user_names_by_id[user_id] =
              visible_user_names_for_pay_periods([ user_id ])[user_id]
          end
        end

        def visible_user_names_for_pay_periods(user_ids)
          return {} if user_ids.empty?

          User.left_outer_joins(:company_assignments)
              .where(id: user_ids)
              .where(
                "users.company_id = :company_id OR users.role = :admin_role OR company_assignments.company_id = :company_id",
                company_id: current_company_id,
                admin_role: User.roles.fetch("admin")
              )
              .distinct
              .pluck("users.id", "users.name")
              .to_h
        end

        def correction_event_json(event)
          {
            id:                       event.id,
            action_type:              event.action_type,
            pay_period_id:            event.pay_period_id,
            resulting_pay_period_id:  event.resulting_pay_period_id,
            actor_id:                 event.actor_id,
            actor_name:               event.actor_name,
            reason:                   event.reason,
            financial_snapshot:       event.financial_snapshot,
            metadata:                 event.metadata,
            created_at:               event.created_at
          }
        end

        def pay_period_correction_summary_json(pay_period)
          {
            id:                pay_period.id,
            period_description: pay_period.period_description,
            status:            pay_period.status,
            correction_status: pay_period.correction_status,
            voided_at:         pay_period.voided_at,
            void_reason:       pay_period.void_reason,
            source_pay_period_id: pay_period.source_pay_period_id,
            superseded_by_id:     pay_period.superseded_by_id
          }
        end

        def parse_iso_date_param(value)
          return nil if value.blank?

          Date.strptime(value.to_s, "%Y-%m-%d")
        end

        # Precompute pre-period YTD totals for all employees in one grouped query
        # and cache the results on the Employee instances so PayrollCalculator
        # can reuse them during run_payroll without N per-employee aggregate reads.
        def preload_ytd_caches!(employees, pay_period)
          return if employees.empty?

          year = pay_period.pay_date.year
          eids = employees.map(&:id)

          committed_period_ids = PayPeriod.reportable_committed
                                          .where(company_id: current_company_id)
                                          .where(pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
                                          .where("(pay_date < ?) OR (pay_date = ? AND id < ?)",
                                                 pay_period.pay_date, pay_period.pay_date, pay_period.id)
                                          .pluck(:id)

          if committed_period_ids.any?
            rows = PayrollItem.where(employee_id: eids, pay_period_id: committed_period_ids)
                              .group(:employee_id)
                              .pluck(
                                :employee_id,
                                Arel.sql("COALESCE(SUM(gross_pay), 0)"),
                                Arel.sql("COALESCE(SUM(net_pay), 0)"),
                                Arel.sql("COALESCE(SUM(withholding_tax), 0)"),
                                Arel.sql("COALESCE(SUM(social_security_tax), 0)"),
                                Arel.sql("COALESCE(SUM(medicare_tax), 0)"),
                                Arel.sql("COALESCE(SUM(additional_withholding), 0)"),
                                Arel.sql("COALESCE(SUM(retirement_payment), 0)"),
                                Arel.sql("COALESCE(SUM(roth_retirement_payment), 0)"),
                                Arel.sql("COALESCE(SUM(insurance_payment), 0)"),
                                Arel.sql("COALESCE(SUM(loan_payment), 0)")
                              )
            ytd_map = rows.each_with_object({}) do |(eid, gross, net, fit, ss, medicare, addl_wh, retirement, roth_retirement, insurance, loans), h|
              h[eid] = {
                gross_pay: gross.to_f,
                net_pay: net.to_f,
                withholding_tax: fit.to_f,
                social_security_tax: ss.to_f,
                medicare_tax: medicare.to_f,
                additional_withholding: addl_wh.to_f,
                retirement: retirement.to_f,
                roth_retirement: roth_retirement.to_f,
                insurance: insurance.to_f,
                loans: loans.to_f
              }
            end
          else
            ytd_map = {}
          end

          employees.each do |emp|
            data = ytd_map[emp.id] || Employee::YTD_AGGREGATE_COLUMNS.keys.index_with { 0.0 }
            emp.cache_ytd_values!(
              year: year,
              as_of_pay_date: pay_period.pay_date,
              before_pay_period_id: pay_period.id,
              totals: data
            )
          end
        end
      end
    end
  end
end
