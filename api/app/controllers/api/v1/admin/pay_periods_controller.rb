# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayPeriodsController < BaseController
        before_action :set_pay_period, only: [
          :show, :update, :destroy, :run_payroll, :approve, :commit, :retry_tax_sync,
          :void, :create_correction_run, :correction_history
        ]

        # GET /api/v1/admin/pay_periods
        def index
          @pay_periods = PayPeriod.where(company_id: current_company_id)
                                   .includes(:payroll_items, :voided_by)
                                   .order(pay_date: :desc)

          # Filter by status
          @pay_periods = @pay_periods.where(status: params[:status]) if params[:status].present?

          # Filter by year
          @pay_periods = @pay_periods.for_year(params[:year].to_i) if params[:year].present?

          render json: {
            pay_periods: @pay_periods.map { |pp| pay_period_json(pp) },
            meta: {
              total: @pay_periods.count,
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
            return render json: { error: "Cannot edit a committed pay period" }, status: :unprocessable_entity
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
            if @pay_period.committed?
              return render json: { error: "Cannot delete a correction run pay period" }, status: :unprocessable_entity
            end

            ActiveRecord::Base.transaction do
              source = nil
              if @pay_period.source_pay_period_id.present?
                source = PayPeriod.lock("FOR UPDATE").find(@pay_period.source_pay_period_id)
                source.update!(superseded_by_id: nil) if source.superseded_by_id == @pay_period.id
              end

              PayPeriodCorrectionEvent.record!(
                action_type: "correction_run_deleted",
                pay_period: source || @pay_period,
                resulting_pay_period: @pay_period,
                actor: current_user,
                reason: "Draft correction run deleted by operator",
                extra_metadata: {
                  deleted_correction_run_id: @pay_period.id
                }
              )

              @pay_period.destroy!
            end

            return head :no_content
          end

          if @pay_period.committed?
            return render json: { error: "Cannot delete a committed pay period" }, status: :unprocessable_entity
          end

          @pay_period.destroy
          head :no_content
        end

        # POST /api/v1/admin/pay_periods/:id/run_payroll
        # Run payroll calculations for all employees in this pay period
        def run_payroll
          unless @pay_period.draft? || @pay_period.calculated?
            return render json: { error: "Can only run payroll on draft or calculated pay periods" }, status: :unprocessable_entity
          end

          # Get employees to include (either from params or all active employees)
          employee_ids = params[:employee_ids] || Employee.active.where(company_id: current_company_id).pluck(:id)

          results = { success: [], errors: [] }

          employee_ids.each do |employee_id|
            employee = Employee.find_by(id: employee_id, company_id: current_company_id)
            next unless employee&.active?

            begin
              # Find or create payroll item for this employee
              payroll_item = @pay_period.payroll_items.find_or_initialize_by(employee_id: employee.id)

              # Set defaults from employee if new record
              if payroll_item.new_record?
                payroll_item.employment_type = employee.employment_type
                payroll_item.pay_rate = employee.pay_rate
                payroll_item.hours_worked = employee.salary? ? 0 : 80 # Default biweekly hours
              end

              # Use hours from params if provided
              if params[:hours] && params[:hours][employee_id.to_s]
                hours_data = params[:hours][employee_id.to_s]
                payroll_item.hours_worked = hours_data[:regular] if hours_data[:regular]
                payroll_item.overtime_hours = hours_data[:overtime] if hours_data[:overtime]
                payroll_item.holiday_hours = hours_data[:holiday] if hours_data[:holiday]
                payroll_item.pto_hours = hours_data[:pto] if hours_data[:pto]
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

            # Update YTD totals for all employees
            @pay_period.payroll_items.each do |item|
              update_ytd_totals(item)
            end

            # Auto-assign check numbers to payroll items that don't have one yet.
            # Uses company-level row lock to prevent collisions across concurrent commits.
            unassigned = @pay_period.payroll_items.where(check_number: nil)
            @pay_period.company.assign_check_numbers!(unassigned) if unassigned.exists?

            # Prepare tax sync (generate idempotency key inside transaction)
            @pay_period.generate_idempotency_key!
            @pay_period.update!(tax_sync_status: "pending")

            # CPR-71: if this is a correction run, write committed audit event atomically
            if @pay_period.correction_run?
              PayPeriodCorrectionService.record_correction_committed!(
                pay_period: @pay_period,
                actor:      current_user
              )
            end
          end

          # Enqueue async tax sync — never block commit
          PayrollTaxSyncJob.perform_later(@pay_period.id)

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

        def set_pay_period
          @pay_period = PayPeriod.includes(:payroll_items, :voided_by, :source_pay_period).find(params[:id])

          unless @pay_period.company_id == current_company_id
            render json: { error: "Pay period not found" }, status: :not_found
          end
        end

        def pay_period_params
          params.require(:pay_period).permit(:start_date, :end_date, :pay_date, :notes)
        end

        def pay_period_json(pay_period, include_items: false)
          json = {
            id: pay_period.id,
            start_date: pay_period.start_date,
            end_date: pay_period.end_date,
            pay_date: pay_period.pay_date,
            status: pay_period.status,
            notes: pay_period.notes,
            period_description: pay_period.period_description,
            employee_count: pay_period.payroll_items.count,
            total_gross: pay_period.payroll_items.sum(:gross_pay),
            total_net: pay_period.payroll_items.sum(:net_pay),
            total_employer_ss: pay_period.payroll_items.sum(:employer_social_security_tax),
            total_employer_medicare: pay_period.payroll_items.sum(:employer_medicare_tax),
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
            can_void:                 pay_period.can_void?,
            can_create_correction_run: pay_period.can_create_correction_run?,
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
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            holiday_hours: item.holiday_hours,
            pto_hours: item.pto_hours,
            bonus: item.bonus,
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            retirement_payment: item.retirement_payment,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            employer_social_security_tax: item.employer_social_security_tax,
            employer_medicare_tax: item.employer_medicare_tax,
            check_number: item.check_number,
            check_printed_at: item.check_printed_at,
            check_print_count: item.check_print_count,
            check_status: item.check_status,
            voided: item.voided,
            voided_at: item.voided_at,
            void_reason: item.void_reason,
            reprint_of_check_number: item.reprint_of_check_number,
            ytd_gross: item.ytd_gross,
            ytd_net: item.ytd_net
          }
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

        def update_ytd_totals(payroll_item)
          employee_ytd = EmployeeYtdTotal.find_or_create_by!(
            employee_id: payroll_item.employee_id,
            year: @pay_period.pay_date.year
          )
          employee_ytd.add_payroll_item!(payroll_item)

          company_ytd = CompanyYtdTotal.find_or_create_by!(
            company_id: @pay_period.company_id,
            year: @pay_period.pay_date.year
          )
          company_ytd.add_payroll_item!(payroll_item)
        end

        def parse_iso_date_param(value)
          return nil if value.blank?

          Date.strptime(value.to_s, "%Y-%m-%d")
        end
      end
    end
  end
end
