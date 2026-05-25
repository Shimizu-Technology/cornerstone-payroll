# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollFieldsController < BaseController
        before_action :set_payroll_field, only: [ :show, :update, :destroy ]

        def index
          fields = PayrollFieldDefinition.where(company_id: current_company_id).ordered
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
        end

        def update
          if @payroll_field.update(payroll_field_params)
            render json: { payroll_field: payroll_field_json(@payroll_field) }
          else
            render json: { errors: @payroll_field.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          @payroll_field.update!(active: false)
          render json: { payroll_field: payroll_field_json(@payroll_field) }
        end

        private

        def set_payroll_field
          @payroll_field = PayrollFieldDefinition.find_by(id: params[:id], company_id: current_company_id)
          return if @payroll_field

          render json: { error: "Payroll field not found" }, status: :not_found
        end

        def payroll_field_params
          params.require(:payroll_field).permit(
            :name, :description, :kind, :tax_treatment, :category, :amount_type,
            :default_amount, :default_percentage, :show_in_payroll_grid, :active,
            :sort_order, :payee_name, :reference_number
          )
        end

        def payroll_field_json(field)
          {
            id: field.id,
            company_id: field.company_id,
            name: field.name,
            description: field.description,
            kind: field.kind,
            tax_treatment: field.tax_treatment,
            category: field.category,
            amount_type: field.amount_type,
            default_amount: field.default_amount&.to_f,
            default_percentage: field.default_percentage&.to_f,
            show_in_payroll_grid: field.show_in_payroll_grid,
            active: field.active,
            sort_order: field.sort_order,
            payee_name: field.payee_name,
            reference_number: field.reference_number,
            created_at: field.created_at,
            updated_at: field.updated_at
          }
        end
      end
    end
  end
end
