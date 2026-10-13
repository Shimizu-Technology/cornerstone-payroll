# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollFieldsController < BaseController
        before_action :set_payroll_field, only: [ :show, :update, :destroy ]

        def index
          fields = PayrollFieldDefinition.where(company_id: current_company_id)
          if params[:employee_id].present?
            employee = Employee.find_by(id: params[:employee_id], company_id: current_company_id)
            return render json: { error: "Employee not found" }, status: :not_found unless employee

            fields = fields.where(owner_employee_id: [ nil, employee.id ])
          else
            fields = fields.client_wide
          end
          fields = fields.includes(:employee_payroll_fields).ordered
          fields = fields.where(active: ActiveModel::Type::Boolean.new.cast(params[:active])) if params.key?(:active)
          render json: { payroll_fields: fields.map { |field| payroll_field_json(field) } }
        end

        def show
          render json: { payroll_field: payroll_field_json(@payroll_field) }
        end

        def create
          field = PayrollFieldDefinition.new(payroll_field_params.merge(company_id: current_company_id))
          if field.save
            render json: { payroll_field: payroll_field_json(field) }, status: :created
          else
            render json: { errors: field.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        def update
          if @payroll_field.update(payroll_field_params)
            render json: { payroll_field: payroll_field_json(@payroll_field) }
          else
            render json: { errors: @payroll_field.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        def destroy
          @payroll_field.update!(active: false)
          render json: { payroll_field: payroll_field_json(@payroll_field) }
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        private

        def set_payroll_field
          @payroll_field = PayrollFieldDefinition.client_wide.find_by(id: params[:id], company_id: current_company_id)
          return if @payroll_field

          render json: { error: "Payroll field not found" }, status: :not_found
        end

        def payroll_field_params
          params.require(:payroll_field).permit(
            :name, :description, :kind, :tax_treatment, :category, :reporting_group, :amount_type,
            :default_amount, :default_percentage, :show_in_payroll_grid, :active,
            :sort_order, :payee_name, :reference_number
          )
        end

        def payroll_field_json(field)
          PayrollFieldSerializer.call(field)
        end
      end
    end
  end
end
