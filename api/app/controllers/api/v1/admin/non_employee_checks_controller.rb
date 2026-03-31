# frozen_string_literal: true

module Api
  module V1
    module Admin
      class NonEmployeeChecksController < BaseController
        before_action :set_check, only: [:show, :update, :destroy, :mark_printed, :void_check, :check_pdf]

        # GET /api/v1/admin/non_employee_checks
        def index
          checks = NonEmployeeCheck.where(company_id: current_company_id)
            .includes(:pay_period, :created_by)

          checks = checks.where(pay_period_id: params[:pay_period_id]) if params[:pay_period_id].present?
          checks = checks.where(check_type: params[:check_type]) if params[:check_type].present?
          checks = checks.active if params[:active] == "true"

          checks = checks.order(created_at: :desc)

          render json: { non_employee_checks: checks.map { |c| check_payload(c) } }
        end

        # GET /api/v1/admin/non_employee_checks/:id
        def show
          render json: { non_employee_check: check_payload(@check) }
        end

        # POST /api/v1/admin/non_employee_checks
        def create
          attrs = check_params.to_h
          pay_period_id = attrs["pay_period_id"] || attrs[:pay_period_id]
          pay_period = resolve_pay_period(pay_period_id) if pay_period_id.present?
          return if pay_period_id.present? && pay_period.nil?

          check = NonEmployeeCheck.new(attrs.except("pay_period_id", :pay_period_id))
          check.company_id = current_company_id
          check.created_by = current_user
          check.pay_period = pay_period if pay_period

          if check.save
            render json: { non_employee_check: check_payload(check) }, status: :created
          else
            render json: { errors: check.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/v1/admin/non_employee_checks/:id
        def update
          if @check.voided?
            return render json: { error: "Cannot update a voided check" }, status: :unprocessable_entity
          end

          attrs = check_params.to_h
          if attrs.key?("pay_period_id") || attrs.key?(:pay_period_id)
            pay_period_id = attrs["pay_period_id"] || attrs[:pay_period_id]
            pay_period = resolve_pay_period(pay_period_id) if pay_period_id.present?
            return if pay_period_id.present? && pay_period.nil?

            attrs["pay_period_id"] = pay_period&.id
          end

          if @check.update(attrs)
            render json: { non_employee_check: check_payload(@check) }
          else
            render json: { errors: @check.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/v1/admin/non_employee_checks/:id
        def destroy
          if @check.printed?
            return render json: { error: "Cannot delete a printed check; void it instead" }, status: :unprocessable_entity
          end

          @check.destroy!
          render json: { message: "Non-employee check deleted" }
        end

        # POST /api/v1/admin/non_employee_checks/:id/mark_printed
        def mark_printed
          @check.mark_printed!
          render json: { non_employee_check: check_payload(@check.reload) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/non_employee_checks/:id/void_check
        def void_check
          reason = params[:reason]
          @check.void!(reason: reason)
          render json: { non_employee_check: check_payload(@check.reload) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/non_employee_checks/:id/check_pdf
        def check_pdf
          generator = NonEmployeeCheckGenerator.new(@check)
          pdf_data  = @check.voided? ? generator.generate_voided : generator.generate

          send_data pdf_data,
            type: "application/pdf",
            disposition: "inline",
            filename: generator.filename
        end

        private

        def set_check
          @check = NonEmployeeCheck.find_by(id: params[:id], company_id: current_company_id)
          return if @check

          render json: { error: "Check not found" }, status: :not_found
        end

        def check_params
          params.require(:non_employee_check).permit(
            :pay_period_id, :payable_to, :amount, :check_type,
            :memo, :description, :reference_number, :check_number
          )
        end

        def resolve_pay_period(pay_period_id)
          pay_period = PayPeriod.find_by(id: pay_period_id, company_id: current_company_id)
          return pay_period if pay_period

          render json: { error: "Pay period not found" }, status: :not_found
          nil
        end

        def check_payload(check)
          {
            id: check.id,
            pay_period_id: check.pay_period_id,
            company_id: check.company_id,
            check_number: check.check_number,
            payable_to: check.payable_to,
            amount: check.amount,
            check_type: check.check_type,
            memo: check.memo,
            description: check.description,
            reference_number: check.reference_number,
            print_count: check.print_count,
            printed_at: check.printed_at,
            voided: check.voided,
            void_reason: check.void_reason,
            voided_at: check.voided_at,
            check_status: check.check_status,
            created_by_id: check.created_by_id,
            created_at: check.created_at,
            updated_at: check.updated_at
          }
        end
      end
    end
  end
end
