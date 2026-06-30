# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CompaniesController < BaseController
        STAFF_EDITABLE_COMPANY_FIELDS = %i[
          address_line1 address_line2 city state zip phone email
        ].freeze
        ADMIN_EDITABLE_COMPANY_FIELDS = (
          %i[
            name ein pay_frequency active address_line1 address_line2 city state zip
            phone email bank_name bank_address check_stock_type check_offset_x check_offset_y
            next_check_number
          ] + [ "check_layout_config" ]
        ).freeze

        skip_before_action :enforce_company_access!, only: [ :index ]

        # GET /api/v1/admin/companies
        # Organization admins see their firm's companies; non-admin staff see assigned clients.
        def index
          accessible_ids = current_user&.accessible_company_ids || []
          companies = Company.where(id: accessible_ids).order(:name)
          companies = companies.where(active: true) if params[:active] == "true"

          company_ids = companies.pluck(:id)
          total_employee_counts = employee_counts_by_company(company_ids)
          active_employee_counts = employee_counts_by_company(company_ids, active_only: true)

          render json: {
            companies: companies.map do |company|
              company_payload(
                company,
                total_employee_counts: total_employee_counts,
                active_employee_counts: active_employee_counts
              )
            end,
            can_manage_clients: current_user&.organization_admin? || false,
            can_view_client_management: staff_client_access?,
            can_switch_company: current_user&.organization_admin? || company_ids.length > 1,
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
          unless current_user&.organization_admin?
            return render json: { error: "Only admins can create companies" }, status: :forbidden
          end

          company = Company.new(company_params)
          company.organization = current_user.organization unless current_user.super_admin? && company.organization.present?

          company.check_stock_type ||= "top_check"
          company.check_offset_x ||= 0.0
          company.check_offset_y ||= 0.0
          company.next_check_number ||= 1001

          unless company.organization
            company.valid?
            return render json: { errors: company.errors.full_messages }, status: :unprocessable_entity
          end

          company.organization.save_company_within_client_limit!(company)
          render json: { company: company_payload(company, detailed: true) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique => e
          render json: { errors: [ "EIN is already taken by another company" ] }, status: :unprocessable_entity
        end

        # PATCH/PUT /api/v1/admin/companies/:id
        def update
          company = Company.find(params[:id])
          unless current_user&.can_access_company?(company.id)
            return render json: { error: "Not authorized" }, status: :forbidden
          end

          unless current_user&.organization_admin? || staff_can_update_company?(company)
            return render json: { error: "Not authorized" }, status: :forbidden
          end

          update_params = current_user&.organization_admin? ? company_params : staff_company_params
          if update_params.blank?
            return render json: { error: "No permitted client fields were provided" }, status: :unprocessable_entity
          end

          normalize_company_check_layout_config!(update_params, company)
          company.assign_attributes(update_params)
          clear_active_printer_profile_if_calibration_changed(company)

          if company.save
            render json: { company: company_payload(company, detailed: true) }
          else
            render json: { errors: company.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordNotUnique => e
          render json: { errors: [ "EIN is already taken by another company" ] }, status: :unprocessable_entity
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

        def staff_company_params
          params.require(:company).permit(*STAFF_EDITABLE_COMPANY_FIELDS)
        end

        def normalize_company_check_layout_config!(update_params, company)
          target_stock_type = update_params[:check_stock_type].presence || company.check_stock_type
          stock_type_changed = update_params.key?(:check_stock_type) && target_stock_type.to_s != company.check_stock_type.to_s

          if update_params.key?(:check_layout_config)
            update_params[:check_layout_config] = CheckLayoutConfigSanitizer.call(
              stock_type: target_stock_type,
              config: update_params[:check_layout_config]
            )
          elsif stock_type_changed
            update_params[:check_layout_config] = {}
          end
        end

        def clear_active_printer_profile_if_calibration_changed(company)
          return unless company.will_save_change_to_check_stock_type? ||
            company.will_save_change_to_check_offset_x? ||
            company.will_save_change_to_check_offset_y? ||
            company.will_save_change_to_check_layout_config?

          company.active_printer_profile = nil
        end

        def company_payload(company, detailed: false, total_employee_counts: nil, active_employee_counts: nil)
          payload = {
            id: company.id,
            name: company.name,
            active: company.active,
            active_employees: active_employee_counts&.fetch(company.id, 0) || company.employees.active.count,
            total_employees: total_employee_counts&.fetch(company.id, 0) || company.employees.count,
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

          payload[:organization_id] = company.organization_id
          payload[:can_update] = current_user&.organization_admin? || staff_can_update_company?(company)
          payload[:editable_fields] = current_user&.organization_admin? ? ADMIN_EDITABLE_COMPANY_FIELDS.map(&:to_s) : STAFF_EDITABLE_COMPANY_FIELDS.map(&:to_s)

          payload
        end

        def staff_client_access?
          current_user&.organization_admin? || current_user&.accountant? || current_user&.manager?
        end

        def staff_can_update_company?(company)
          staff_client_access? && current_user&.can_access_company?(company.id)
        end

        def employee_counts_by_company(company_ids, active_only: false)
          return {} if company_ids.empty?

          scope = Employee.where(company_id: company_ids)
          scope = scope.active if active_only
          scope.group(:company_id).count
        end
      end
    end
  end
end
