# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayPeriodsController < BaseController
        include Auditable
        audit_actions :approve, :unapprove, :commit, :run_payroll, :void, :create_correction_run
        before_action :set_pay_period, only: [
          :show, :update, :destroy, :run_payroll, :approve, :unapprove, :commit, :retry_tax_sync,
          :void, :create_correction_run, :correction_history
        ]

        # GET /api/v1/admin/pay_periods
        def index
          @pay_periods = PayPeriod.where(company_id: current_company_id)
                                   .includes(:payroll_items, :voided_by, :correction_events)
                                   .order(pay_date: :desc)

          # Filter by status
          @pay_periods = @pay_periods.where(status: params[:status]) if params[:status].present?

          # Filter by year
          @pay_periods = @pay_periods.for_year(params[:year].to_i) if params[:year].present?

          loaded = @pay_periods.to_a
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

          if @pay_period.update(pay_period_params)
            render json: { pay_period: pay_period_json(@pay_period) }
          else
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
          employee_ids = if params[:employee_ids].present?
            Array(params[:employee_ids])
          elsif @pay_period.payroll_items.where.not(import_source: [ nil, "" ]).exists?
            imported_ids = @pay_period.payroll_items.pluck(:employee_id)
            salary_ids = Employee.active.where(company_id: current_company_id, employment_type: "salary").pluck(:id)
            contractor_ids = Employee.active.where(company_id: current_company_id, employment_type: "contractor").pluck(:id)
            (imported_ids + salary_ids + contractor_ids).uniq
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
                payroll_item.pay_rate = employee.primary_wage_rate&.rate || employee.pay_rate
                payroll_item.hours_worked = if employee.salary? || employee.contractor_flat_fee?
                                             0
                                           else
                                             80
                                           end
              end

              # Use hours from params if provided
              if params[:hours] && params[:hours][employee_id.to_s]
                hours_data = params[:hours][employee_id.to_s]
                wage_rate_hours = hours_data[:wage_rates] || hours_data["wage_rates"]

                if wage_rate_hours.present?
                  apply_wage_rate_hours(payroll_item, wage_rate_hours, employee)
                else
                  payroll_item.clear_wage_rate_hours!
                  payroll_item.hours_worked = hours_data[:regular] if hours_data[:regular]
                  payroll_item.overtime_hours = hours_data[:overtime] if hours_data[:overtime]
                  payroll_item.holiday_hours = hours_data[:holiday] if hours_data[:holiday]
                  payroll_item.pto_hours = hours_data[:pto] if hours_data[:pto]
                end
              end

              # Calculate payroll
              payroll_item.calculate!
              results[:success] << { employee_id: employee.id, name: employee.full_name }
            rescue StandardError => e
              results[:errors] << { employee_id: employee.id, error: e.message }
            end
          end

          # Update pay period status
          @pay_period.update!(status: "calculated") if results[:errors].empty?

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

          @pay_period.update!(status: "approved", approved_by_id: current_user_id)
          render json: { pay_period: pay_period_json(@pay_period) }
        end

        # POST /api/v1/admin/pay_periods/:id/unapprove
        # Roll back an approved pay period to calculated status.
        def unapprove
          unless @pay_period.approved?
            return render json: { error: "Can only unapprove an approved pay period" }, status: :unprocessable_entity
          end

          @pay_period.update!(status: "calculated", approved_by_id: nil)
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
            @pay_period.update!(status: "committed", committed_at: Time.current)
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

        def create_fit_tax_deposit_check!(items)
          w2_items = items.select { |i| i.employment_type != "contractor" && !i.voided? }
          total_fit = w2_items.sum { |i| i.withholding_tax.to_d }
          return if total_fit <= 0

          NonEmployeeCheck.create!(
            pay_period: @pay_period,
            company_id: @pay_period.company_id,
            payable_to: "EFTPS - Federal Income Tax",
            amount: total_fit,
            check_type: "tax_deposit",
            memo: "FIT deposit for PPE #{@pay_period.end_date.strftime('%m/%d/%Y')}",
            description: "Auto-generated FIT tax deposit for payroll commit",
            created_by: current_user
          )
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
          @pay_period = PayPeriod.includes(:payroll_items, :voided_by, :source_pay_period, :correction_events).find(params[:id])

          unless @pay_period.company_id == current_company_id
            render json: { error: "Pay period not found" }, status: :not_found
          end
        end

        def pay_period_params
          params.require(:pay_period).permit(:start_date, :end_date, :pay_date, :notes)
        end

        def pay_period_json(pay_period, include_items: false)
          agg = pay_period_aggregates(pay_period)

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
            committed_at: pay_period.committed_at,
            tax_sync_status: pay_period.tax_sync_status,
            tax_sync_attempts: pay_period.tax_sync_attempts,
            tax_sync_last_error: pay_period.tax_sync_last_error,
            tax_synced_at: pay_period.tax_synced_at,
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
            created_at: pay_period.created_at,
            updated_at: pay_period.updated_at
          }

          if include_items
            json[:payroll_items] = pay_period.payroll_items.includes(:employee).map do |item|
              payroll_item_json(item)
            end
          end

          json
        end

        def payroll_item_json(item)
          {
            id: item.id,
            employee_id: item.employee_id,
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
            additional_withholding: item.additional_withholding,
            withholding_tax_override: item.withholding_tax_override,
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
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
            check_number: item.check_number,
            check_printed_at: item.check_printed_at,
            check_print_count: item.check_print_count,
            check_status: item.check_status,
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

        # Precompute YTD gross and social security for all employees in one query
        # and cache the values on the Employee instances so PayrollCalculator
        # doesn't issue 2×N individual queries during run_payroll.
        def preload_ytd_caches!(employees, pay_period)
          return if employees.empty?

          year = pay_period.pay_date.year
          eids = employees.map(&:id)

          committed_period_ids = PayPeriod.reportable_committed
                                          .where(company_id: current_company_id)
                                          .for_year(year)
                                          .pluck(:id)

          if committed_period_ids.any?
            rows = PayrollItem.where(employee_id: eids, pay_period_id: committed_period_ids)
                              .group(:employee_id)
                              .pluck(
                                :employee_id,
                                Arel.sql("COALESCE(SUM(gross_pay), 0)"),
                                Arel.sql("COALESCE(SUM(social_security_tax), 0)")
                              )
            ytd_map = rows.each_with_object({}) do |(eid, gross, ss), h|
              h[eid] = { gross: gross.to_f, ss: ss.to_f }
            end
          else
            ytd_map = {}
          end

          employees.each do |emp|
            data = ytd_map[emp.id] || { gross: 0.0, ss: 0.0 }
            emp.cached_ytd_gross = data[:gross]
            emp.cached_ytd_social_security = data[:ss]
          end
        end
      end
    end
  end
end
