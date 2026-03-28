# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CompaniesController < BaseController
        # GET /api/v1/admin/companies
        # Super admins see all companies; accountants see assigned companies;
        # regular users see only their own.
        def index
          accessible_ids = current_user&.accessible_company_ids || []
          companies = Company.where(id: accessible_ids).order(:name)
          companies = companies.where(active: true) if params[:active] == "true"

          render json: {
            companies: companies.map { |c| company_payload(c) },
            is_super_admin: current_user&.super_admin? || false,
            can_switch_company: current_user&.super_admin? || accessible_ids.length > 1,
            current_company_id: current_company_id
          }
        end

        # GET /api/v1/admin/companies/:id
        def show
          company = Company.find(params[:id])
          unless current_user&.can_access_company?(company.id)
            return render json: { error: "Not authorized" }, status: :forbidden
          end

          render json: { company: company_payload(company, detailed: true) }
        end

        # POST /api/v1/admin/companies
        def create
          unless current_user&.super_admin?
            return render json: { error: "Only super admins can create companies" }, status: :forbidden
          end

          company = Company.new(company_params)
          company.check_stock_type ||= "bottom_check"
          company.check_offset_x ||= 0.0
          company.check_offset_y ||= 0.0
          company.next_check_number ||= 1001

          if company.save
            render json: { company: company_payload(company, detailed: true) }, status: :created
          else
            render json: { errors: company.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordNotUnique => e
          render json: { errors: ["EIN is already taken by another company"] }, status: :unprocessable_entity
        end

        # PATCH/PUT /api/v1/admin/companies/:id
        def update
          company = Company.find(params[:id])
          unless current_user&.super_admin?
            return render json: { error: "Only super admins can update companies" }, status: :forbidden
          end

          if company.update(company_params)
            render json: { company: company_payload(company, detailed: true) }
          else
            render json: { errors: company.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordNotUnique => e
          render json: { errors: ["EIN is already taken by another company"] }, status: :unprocessable_entity
        end

        private

        def company_params
          params.require(:company).permit(
            :name, :ein, :pay_frequency, :active,
            :address_line1, :address_line2, :city, :state, :zip,
            :phone, :email,
            :bank_name, :bank_address,
            :check_stock_type, :check_offset_x, :check_offset_y,
            :next_check_number,
            check_layout_config: {}
          )
        end

        def company_payload(company, detailed: false)
          payload = {
            id: company.id,
            name: company.name,
            active: company.active,
            active_employees: company.employees.active.count,
            total_employees: company.employees.count,
            pay_frequency: company.pay_frequency
          }

          if detailed
            payload.merge!(
              address_line1: company.address_line1,
              address_line2: company.address_line2,
              city: company.city,
              state: company.state,
              zip: company.zip,
              ein: company.ein,
              phone: company.phone,
              email: company.email,
              bank_name: company.bank_name,
              bank_address: company.bank_address,
              check_stock_type: company.check_stock_type,
              check_offset_x: company.check_offset_x,
              check_offset_y: company.check_offset_y,
              check_layout_config: company.check_layout_config || {},
              next_check_number: company.next_check_number
            )
          end

          payload
        end
      end
    end
  end
end
