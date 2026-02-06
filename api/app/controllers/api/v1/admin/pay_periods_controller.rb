# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayPeriodsController < ApplicationController
        before_action :set_pay_period, only: [ :show, :update, :destroy, :run_payroll, :approve, :commit ]

        # GET /api/v1/admin/pay_periods
        def index
          @pay_periods = PayPeriod.where(company_id: current_company_id)
                                   .includes(:payroll_items)
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

          ActiveRecord::Base.transaction do
            @pay_period.update!(status: "committed", committed_at: Time.current)

            # Update YTD totals for all employees
            @pay_period.payroll_items.each do |item|
              update_ytd_totals(item)
            end
          end

          render json: { pay_period: pay_period_json(@pay_period) }
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.includes(:payroll_items).find(params[:id])

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
            committed_at: pay_period.committed_at,
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
            check_number: item.check_number,
            ytd_gross: item.ytd_gross,
            ytd_net: item.ytd_net
          }
        end

        def update_ytd_totals(payroll_item)
          ytd = EmployeeYtdTotal.find_or_create_by!(
            employee_id: payroll_item.employee_id,
            year: @pay_period.pay_date.year
          )
          ytd.add_payroll_item!(payroll_item)
        end

        # Temporary helpers until auth is integrated
        def current_company_id
          ENV.fetch("COMPANY_ID", 1).to_i
        end

        def current_user_id
          ENV.fetch("USER_ID", 1).to_i
        end
      end
    end
  end
end
