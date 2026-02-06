# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollItemsController < BaseController
        before_action :set_pay_period
        before_action :set_payroll_item, only: [ :show, :update, :destroy, :recalculate ]

        # GET /api/v1/admin/pay_periods/:pay_period_id/payroll_items
        def index
          @payroll_items = @pay_period.payroll_items.includes(:employee)

          render json: {
            payroll_items: @payroll_items.map { |item| payroll_item_json(item) },
            summary: {
              total_gross: @payroll_items.sum(:gross_pay),
              total_withholding: @payroll_items.sum(:withholding_tax),
              total_social_security: @payroll_items.sum(:social_security_tax),
              total_medicare: @payroll_items.sum(:medicare_tax),
              total_deductions: @payroll_items.sum(:total_deductions),
              total_net: @payroll_items.sum(:net_pay),
              employee_count: @payroll_items.count
            }
          }
        end

        # GET /api/v1/admin/pay_periods/:pay_period_id/payroll_items/:id
        def show
          render json: { payroll_item: payroll_item_json(@payroll_item, detailed: true) }
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/payroll_items
        # Add an employee to this pay period
        def create
          unless @pay_period.can_edit?
            return render json: { error: "Cannot modify a committed pay period" }, status: :unprocessable_entity
          end

          employee = Employee.find_by(id: params[:employee_id], company_id: current_company_id)
          unless employee
            return render json: { error: "Employee not found" }, status: :not_found
          end

          @payroll_item = @pay_period.payroll_items.build(payroll_item_params)
          @payroll_item.employee = employee
          @payroll_item.employment_type ||= employee.employment_type
          @payroll_item.pay_rate ||= employee.pay_rate

          if @payroll_item.save
            @payroll_item.calculate! if params[:auto_calculate]
            render json: { payroll_item: payroll_item_json(@payroll_item) }, status: :created
          else
            render json: { errors: @payroll_item.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH/PUT /api/v1/admin/pay_periods/:pay_period_id/payroll_items/:id
        def update
          unless @pay_period.can_edit?
            return render json: { error: "Cannot modify a committed pay period" }, status: :unprocessable_entity
          end

          if @payroll_item.update(payroll_item_params)
            @payroll_item.calculate! if params[:auto_calculate]
            render json: { payroll_item: payroll_item_json(@payroll_item) }
          else
            render json: { errors: @payroll_item.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/v1/admin/pay_periods/:pay_period_id/payroll_items/:id
        def destroy
          unless @pay_period.can_edit?
            return render json: { error: "Cannot modify a committed pay period" }, status: :unprocessable_entity
          end

          @payroll_item.destroy
          head :no_content
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/payroll_items/:id/recalculate
        def recalculate
          unless @pay_period.can_edit?
            return render json: { error: "Cannot modify a committed pay period" }, status: :unprocessable_entity
          end

          @payroll_item.calculate!
          render json: { payroll_item: payroll_item_json(@payroll_item) }
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.find(params[:pay_period_id])

          unless @pay_period.company_id == current_company_id
            render json: { error: "Pay period not found" }, status: :not_found
          end
        end

        def set_payroll_item
          @payroll_item = @pay_period.payroll_items.find(params[:id])
        end

        def payroll_item_params
          params.require(:payroll_item).permit(
            :employee_id, :employment_type, :pay_rate,
            :hours_worked, :overtime_hours, :holiday_hours, :pto_hours,
            :bonus, :additional_withholding, :check_number
          )
        end

        def payroll_item_json(item, detailed: false)
          json = {
            id: item.id,
            employee_id: item.employee_id,
            employee_name: item.employee_full_name,
            employment_type: item.employment_type,
            pay_rate: item.pay_rate,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            holiday_hours: item.holiday_hours,
            pto_hours: item.pto_hours,
            total_hours: item.total_hours,
            bonus: item.bonus,
            reported_tips: item.reported_tips,
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            retirement_payment: item.retirement_payment,
            additional_withholding: item.additional_withholding,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            check_number: item.check_number,
            check_printed_at: item.check_printed_at,
            ytd_gross: item.ytd_gross,
            ytd_net: item.ytd_net
          }

          if detailed
            # Include full YTD breakdown
            json[:ytd] = {
              gross: item.ytd_gross,
              net: item.ytd_net,
              withholding_tax: item.ytd_withholding_tax,
              social_security_tax: item.ytd_social_security_tax,
              medicare_tax: item.ytd_medicare_tax,
              retirement: item.ytd_retirement
            }
          end

          json
        end

      end
    end
  end
end
