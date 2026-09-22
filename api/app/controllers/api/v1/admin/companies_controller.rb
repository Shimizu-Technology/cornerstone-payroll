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
            next_check_number simple_payroll_register_enabled historical_payroll_enabled
            client_payroll_approval_required
          ] + [ "check_layout_config" ]
        ).freeze

        skip_before_action :enforce_company_access!, only: [ :index ]
        skip_before_action :enforce_test_workspace_access!, only: %i[
          index create migration_rehearsal_preview create_migration_rehearsal retry_migration_rehearsal
          training_replay_preview create_training_replay retry_training_replay
          test_workspace_preview create_test_workspace retry_test_workspace archive_test_workspace restore_test_workspace
          migration_promotion_preview create_migration_promotion_backup apply_migration_promotion
        ]
        skip_before_action :enforce_test_workspace_safety!, only: %i[
          index create migration_rehearsal_preview create_migration_rehearsal retry_migration_rehearsal
          training_replay_preview create_training_replay retry_training_replay
          test_workspace_preview create_test_workspace retry_test_workspace archive_test_workspace restore_test_workspace
          migration_promotion_preview create_migration_promotion_backup apply_migration_promotion
        ]

        # GET /api/v1/admin/companies
        # Organization admins see their firm's companies; non-admin staff see assigned clients.
        def index
          accessible_ids = current_user&.accessible_company_ids || []
          companies = Company.where(id: accessible_ids).includes(:migration_source_company).order(:name)
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

        # GET /api/v1/admin/companies/:id/migration_rehearsal_preview
        def migration_rehearsal_preview
          source = accessible_company!
          batch = selected_locked_batch(source)
          render json: { migration_rehearsal: MigrationRehearsal::Preview.new(source_company: source, batch: batch).call }
        end

        # POST /api/v1/admin/companies/:id/migration_rehearsal
        def create_migration_rehearsal
          source = accessible_company!
          company = MigrationRehearsal::Create.new(
            source_company: source,
            actor: current_user,
            name: params[:name],
            acknowledgement: params[:acknowledgement],
            batch: selected_locked_batch(source)
          ).call
          render json: { company: company_payload(company, detailed: true) }, status: :accepted
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_service_errors(e)
        end

        # POST /api/v1/admin/companies/:id/retry_migration_rehearsal
        def retry_migration_rehearsal
          company = accessible_company!
          company = MigrationRehearsal::Retry.new(company: company, actor: current_user).call
          render json: { company: company_payload(company, detailed: true) }, status: :accepted
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_service_errors(e)
        end

        # GET /api/v1/admin/companies/:id/training_replay_preview
        def training_replay_preview
          source = accessible_company!
          render json: { training_replay: TrainingReplay::Preview.new(source_company: source).call }
        end

        # POST /api/v1/admin/companies/:id/training_replay
        def create_training_replay
          source = accessible_company!
          company = TrainingReplay::Create.new(
            source_company: source,
            actor: current_user,
            name: params[:name],
            acknowledgement: params[:acknowledgement],
            assignments: training_replay_assignments
          ).call
          render json: { company: company_payload(company, detailed: true) }, status: :accepted
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_service_errors(e)
        end

        # POST /api/v1/admin/companies/:id/retry_training_replay
        def retry_training_replay
          company = accessible_company!
          company = TrainingReplay::Retry.new(company: company, actor: current_user).call
          render json: { company: company_payload(company, detailed: true) }, status: :accepted
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_service_errors(e)
        end

        # GET /api/v1/admin/companies/:id/test_workspace_preview
        def test_workspace_preview
          source = accessible_company!
          render json: {
            test_workspace: TestWorkspace::Preview.new(
              source_company: source,
              copy_mode: params[:copy_mode].presence || "all_committed",
              excluded_payrolls: params[:excluded_payrolls].presence || 2,
              cutoff_pay_period_id: params[:cutoff_pay_period_id]
            ).call
          }
        end

        # POST /api/v1/admin/companies/:id/test_workspace
        def create_test_workspace
          source = accessible_company!
          company = TestWorkspace::Create.new(
            source_company: source,
            actor: current_user,
            name: params[:name],
            acknowledgement: params[:acknowledgement],
            assignments: test_workspace_assignments,
            copy_mode: params[:copy_mode].presence || "all_committed",
            excluded_payrolls: params[:excluded_payrolls].presence || 2,
            cutoff_pay_period_id: params[:cutoff_pay_period_id],
            expiration_days: params[:expiration_days].presence || 90
          ).call
          render json: { company: company_payload(company, detailed: true) }, status: :accepted
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_service_errors(e)
        end

        # POST /api/v1/admin/companies/:id/retry_test_workspace
        def retry_test_workspace
          company = accessible_company!
          company = TestWorkspace::Retry.new(company: company, actor: current_user).call
          render json: { company: company_payload(company, detailed: true) }, status: :accepted
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_service_errors(e)
        end

        # POST /api/v1/admin/companies/:id/archive_test_workspace
        def archive_test_workspace
          company = accessible_company!
          company = TestWorkspace::Lifecycle.new(company: company, actor: current_user).archive!
          render json: { company: company_payload(company, detailed: true) }
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_service_errors(e)
        end

        # POST /api/v1/admin/companies/:id/restore_test_workspace
        def restore_test_workspace
          company = accessible_company!
          company = TestWorkspace::Lifecycle.new(company: company, actor: current_user).restore!
          render json: { company: company_payload(company, detailed: true) }
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_service_errors(e)
        end

        # GET /api/v1/admin/companies/:id/migration_promotion_preview
        def migration_promotion_preview
          rehearsal = accessible_company!
          render json: { migration_promotion: MigrationPromotion::Preview.new(rehearsal: rehearsal).call }
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_service_errors(e)
        end

        # POST /api/v1/admin/companies/:id/migration_promotion_backup
        def create_migration_promotion_backup
          rehearsal = accessible_company!
          backup = MigrationPromotion::CreateBackup.new(
            rehearsal: rehearsal,
            actor: current_user,
            acknowledgement: params[:acknowledgement]
          ).call
          render json: { company: company_payload(backup, detailed: true) }, status: :accepted
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_service_errors(e)
        end

        # POST /api/v1/admin/companies/:id/migration_promotion
        def apply_migration_promotion
          rehearsal = accessible_company!
          periods = MigrationPromotion::Apply.new(
            rehearsal: rehearsal,
            actor: current_user,
            acknowledgement: params[:acknowledgement],
            payment_dispositions: payment_disposition_params
          ).call
          render json: {
            company: company_payload(rehearsal.migration_source_company.reload, detailed: true),
            promoted_pay_period_ids: periods.map(&:id)
          }
        rescue ActionController::ParameterMissing, ArgumentError, ActiveRecord::RecordInvalid => e
          render_service_errors(e)
        end

        # PATCH/PUT /api/v1/admin/companies/:id
        def update
          company = Company.find(params[:id])
          unless current_user&.can_access_company?(company.id)
            return render json: { error: "Not authorized" }, status: :forbidden
          end

          unless can_update_company?(company)
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
            :next_check_number, :simple_payroll_register_enabled, :historical_payroll_enabled,
            :client_payroll_approval_required,
            check_layout_config: {}
          )
        end

        def training_replay_assignments
          params.permit(assignments: %i[user_id workspace_access_level]).fetch(:assignments, [])
        end

        def test_workspace_assignments
          params.permit(assignments: %i[user_id workspace_access_level]).fetch(:assignments, [])
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
            pay_frequency: company.pay_frequency,
            historical_payroll_enabled: company.historical_payroll_enabled,
            client_payroll_approval_required: company.client_payroll_approval_required,
            payroll_environment: company.payroll_environment,
            test_workspace: company.test_workspace?,
            test_workspace_purpose: company.test_workspace_purpose,
            test_workspace_purpose_label: company.test_workspace_purpose_label,
            test_workspace_manifest: company.test_workspace_manifest,
            test_workspace_expires_at: company.test_workspace_expires_at,
            test_workspace_archived_at: company.test_workspace_archived_at,
            test_workspace_sealed_at: company.test_workspace_sealed_at,
            test_workspace_expired: company.test_workspace_expired?,
            test_workspace_read_only: company.test_workspace_read_only?,
            migration_rehearsal_status: company.migration_rehearsal_status,
            migration_source_company_id: company.migration_source_company_id,
            migration_source_company_name: company.migration_source_company&.name,
            migration_source_batch_id: company.migration_source_batch_id,
            migration_rehearsal_completed_at: company.migration_rehearsal_completed_at,
            migration_rehearsal_error: company.migration_rehearsal_error
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
              next_check_number: company.next_check_number,
              require_distinct_check_print_confirmer: company.require_distinct_check_print_confirmer,
              simple_payroll_register_enabled: company.simple_payroll_register_enabled,
              historical_payroll_enabled: company.historical_payroll_enabled,
              client_payroll_approval_required: company.client_payroll_approval_required
            )
          end

          can_update = can_update_company?(company)
          payload[:organization_id] = company.organization_id
          payload[:can_update] = can_update
          payload[:editable_fields] = if can_update
            current_user&.organization_admin? ? ADMIN_EDITABLE_COMPANY_FIELDS.map(&:to_s) : STAFF_EDITABLE_COMPANY_FIELDS.map(&:to_s)
          else
            []
          end

          payload
        end

        def can_update_company?(company)
          role_allows_update = current_user&.organization_admin? || staff_can_update_company?(company)
          return false unless role_allows_update

          TestWorkspaceAccessPolicy.allowed?(
            user: current_user,
            company: company,
            request_method: "PATCH",
            capability: :manage_client_configuration
          )
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

        def accessible_company!
          company = Company.find(params[:id])
          raise ActiveRecord::RecordNotFound unless current_user&.can_access_company?(company.id)

          company
        end

        def payment_disposition_params
          dispositions = params.require(:payment_dispositions)
          unless dispositions.is_a?(ActionController::Parameters)
            raise ArgumentError, "Choose whether each rehearsal payroll was already paid or should be processed in Cornerstone"
          end

          dispositions.each_pair.to_h do |period_id, disposition|
            [ period_id.to_s, disposition.to_s ]
          end
        end

        def render_service_errors(error)
          messages = error.respond_to?(:record) && error.record ? error.record.errors.full_messages : [ error.message ]
          render json: { errors: messages }, status: :unprocessable_entity
        end

        def selected_locked_batch(company)
          return company.historical_import_batches.where(status: "locked").recent_first.first if params[:historical_import_batch_id].blank?

          company.historical_import_batches.where(status: "locked").find(params[:historical_import_batch_id])
        end
      end
    end
  end
end
