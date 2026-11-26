# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CompaniesController < BaseController
        STAFF_EDITABLE_COMPANY_FIELDS = %i[
          address_line1 address_line2 city state zip phone email filing_contact_name
        ].freeze
        ADMIN_EDITABLE_COMPANY_FIELDS = (
          %i[
            filing_contact_name kind_of_employer employment_code establishment_number name ein pay_frequency active address_line1 address_line2 city state zip
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
          companies = Company.where(id: accessible_ids).includes(:organization, :migration_source_company, :created_by).order(:name)
          companies = companies.where(active: true) if params[:active] == "true"

          company_ids = companies.pluck(:id)
          total_employee_counts = employee_counts_by_company(company_ids)
          active_employee_counts = employee_counts_by_company(company_ids, active_only: true)
          @company_creators = RecordCreator.for_companies(companies.to_a)

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
          @created_company_for_audit = company
          render json: { company: company_payload(company, detailed: true) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique => e
          render_company_uniqueness_error(e)
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
          apply_args = {
            rehearsal: rehearsal,
            actor: current_user,
            acknowledgement: params[:acknowledgement],
            payment_dispositions: payment_disposition_params
          }
          if params[:replace_contact_employee_ids].present?
            apply_args[:replace_contact_employee_ids] = Array(params[:replace_contact_employee_ids])
          end
          periods = MigrationPromotion::Apply.new(**apply_args).call
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

          full_management = full_company_management?(company)
          update_params = full_management ? company_params : staff_company_params
          if update_params.blank?
            return render json: { error: "No permitted client fields were provided" }, status: :unprocessable_entity
          end

          company.with_lock(requires_new: true) do
            revalidate_current_company_write_access!(company: company,
              capability: full_management ? :manage_client_administration : nil)
            update_params = full_company_management?(company) ? company_params : staff_company_params
            before_updated_at = company.updated_at
            normalize_company_check_layout_config!(update_params, company)
            company.assign_attributes(update_params)
            disabling_approval = company.client_payroll_approval_required_in_database && !company.client_payroll_approval_required?
            if disabling_approval
              unless StaffRolePolicy.allowed?(current_user, :override_client_approval)
                return render json: { error: "Admin access required" }, status: :forbidden
              end
              reason = params.dig(:company, :client_approval_disable_reason)
              reason = reason.is_a?(String) ? reason.strip : ""
              unless PayrollReviewPackage::OVERRIDE_REASON_LENGTH.cover?(reason.length)
                return render json: { error: "Enter a reason of 10–500 characters to turn off client approval." }, status: :unprocessable_entity
              end

              reviews = PayrollReviewPackage.where(company_id: company.id)
              open_runs = company.pay_periods.where(status: %w[calculated approved])
                .or(company.pay_periods.where(status: "draft", id: reviews.select(:pay_period_id)))
              finalized_runs_with_review = company.pay_periods.where(status: "committed",
                id: reviews.where.not(published_at: nil).select(:pay_period_id))
              open_runs.or(finalized_runs_with_review).where(client_approval_retained: false)
                .update_all(client_approval_retained: true)
            end
            clear_active_printer_profile_if_calibration_changed(company)
            company.save!
            actual_fields = company.saved_changes.keys - [ "updated_at" ]
            name_only = actual_fields == [ "name" ]
            safe_changes = AuditRecordSnapshot.changes_for(company)
            AuditLog.record!(
              user: current_user, company_id: company.id, organization_id: company.organization_id,
              action: name_only ? "company#name_changed" : "companies#update",
              record_type: "Company", record_id: company.id, subject_name: company.name,
              metadata: safe_changes.merge(disabling_approval ? { client_approval_disable_reason: reason } : {}).merge(
                changed_fields: actual_fields, actual_changes: true, name_only: name_only,
                company_updated_at_before: before_updated_at&.utc&.iso8601(6),
                company_updated_at_after: company.updated_at.utc.iso8601(6)
              ), ip_address: request.remote_ip
            )
          end
          render json: { company: company_payload(company, detailed: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique => e
          render_company_uniqueness_error(e)
        end

        private

        def rls_system_reason
          "Company administration spans authorized source and target companies"
        end

        def render_company_uniqueness_error(error)
          constraint = error.cause&.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME)
          message = if constraint.in?(%w[index_live_companies_on_lower_subdomain_slug index_live_and_demo_companies_on_lower_subdomain_slug])
            "Subdomain slug is already taken by another company"
          else
            "EIN is already taken by another company"
          end
          render json: { errors: [ message ] }, status: :unprocessable_entity
        end

        # A newly created client is not the client selected before the request.
        def audit_company_id
          return @created_company_for_audit.id if action_name == "create" && @created_company_for_audit

          super
        end

        def company_params
          params.require(:company).permit(
            :filing_contact_name, :kind_of_employer, :employment_code, :establishment_number,
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

        def company_creator_payload(company)
          return unless StaffRolePolicy.allowed?(current_user, :staff_workspace)
          return @company_creators[company.id] if @company_creators&.key?(company.id)

          RecordCreator.call(company)
        end

        def company_payload(company, detailed: false, total_employee_counts: nil, active_employee_counts: nil)
          payload = {
            creator: company_creator_payload(company),
            id: company.id,
            organization_id: company.organization_id,
            organization_name: company.organization.name,
            name: company.name,
            active: company.active,
            active_employees: active_employee_counts&.fetch(company.id, 0) || company.employees.active.count,
            total_employees: total_employee_counts&.fetch(company.id, 0) || company.employees.count,
            pay_frequency: company.pay_frequency,
            historical_payroll_enabled: company.historical_payroll_enabled,
            client_capabilities: StaffRolePolicy.capabilities_for(current_user, company: company),
            client_management: StaffRolePolicy.client_management_allowed?(current_user, company),
            client_payroll_approval_required: company.client_payroll_approval_required,
            **CompanyWorkspacePresentation.fields(company, manifest: true)
          }
          company_type = CompanyWorkspacePresentation.company_type(company, viewer: current_user)
          payload[:company_type] = company_type if company_type

          if detailed
            payload.merge!(
              address_line1: company.address_line1,
              address_line2: company.address_line2,
              city: company.city,
              state: company.state,
              zip: company.zip,
              ein: company.ein,
              filing_contact_name: company.filing_contact_name, kind_of_employer: company.kind_of_employer, employment_code: company.employment_code, establishment_number: company.establishment_number,
              phone: company.phone,
              email: company.email,
              bank_name: company.bank_name,
              bank_address: company.bank_address,
              check_stock_type: company.check_stock_type,
              check_offset_x: company.check_offset_x,
              check_offset_y: company.check_offset_y,
              check_layout_config: company.check_layout_config || {},
              next_check_number: company.next_check_number,
              simple_payroll_register_enabled: company.simple_payroll_register_enabled,
              historical_payroll_enabled: company.historical_payroll_enabled,
              client_payroll_approval_required: company.client_payroll_approval_required
            )
          end

          can_update = can_update_company?(company)
          payload[:organization_id] = company.organization_id
          payload[:can_update] = can_update
          payload[:editable_fields] = if can_update
            full_company_management?(company) ? ADMIN_EDITABLE_COMPANY_FIELDS.map(&:to_s) : STAFF_EDITABLE_COMPANY_FIELDS.map(&:to_s)
          else
            []
          end

          payload
        end

        # A test workspace's identity, status and bank/check setup stay with
        # organization admins (archive and restore are the status path), as a
        # Client management grant never applies to a test workspace either.
        def full_company_management?(company)
          return false if company.practice_copy? && !current_user&.organization_admin?

          StaffRolePolicy.allowed?(current_user, :manage_client_administration, company: company)
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
