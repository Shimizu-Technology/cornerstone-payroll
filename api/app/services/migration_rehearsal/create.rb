# frozen_string_literal: true

module MigrationRehearsal
  class Create
    ACKNOWLEDGEMENT = "CREATE MIGRATION REHEARSAL"
    COMPANY_FIELDS = %w[
      address_line1 address_line2 city state zip ein phone email bank_name bank_address
      pay_frequency simple_payroll_register_enabled historical_payroll_enabled check_stock_type
      check_offset_x check_offset_y check_layout_config next_check_number active_printer_profile_id
    ].freeze

    def initialize(source_company:, actor:, acknowledgement:, name: nil, batch: nil)
      @source_company = source_company
      @actor = actor
      @name = name.to_s.strip.presence || "#{source_company.name} Migration Test"
      @acknowledgement = acknowledgement
      @batch = batch || source_company.historical_import_batches.where(status: "locked").recent_first.first
    end

    def call
      authorize!
      raise ArgumentError, "Confirm that this rehearsal contains protected payroll data" unless acknowledgement == ACKNOWLEDGEMENT

      preview = Preview.new(source_company: source_company, batch: batch).call
      raise ArgumentError, preview.fetch(:blockers).join("; ") unless preview.fetch(:ready)

      company = Company.new(source_company.attributes.slice(*COMPANY_FIELDS).merge(
        name: name,
        organization: source_company.organization,
        active: true,
        payroll_environment: "migration_rehearsal",
        migration_source_company: source_company,
        migration_source_batch: batch,
        migration_rehearsal_status: "pending",
        migration_rehearsal_created_by: actor,
        migration_rehearsal_created_at: Time.current,
        migration_rehearsal_error: nil,
        auto_create_fit_check: false,
        payroll_intake_source_types: []
      ))

      Company.transaction do
        source_company.organization.lock!
        if source_company.migration_rehearsals.active.exists?
          raise ArgumentError, "Archive the existing migration rehearsal before creating another"
        end

        company.save!
        AuditLog.record!(
          user: actor,
          organization_id: company.organization_id,
          company_id: company.id,
          action: "migration_rehearsal#create",
          record_type: "companies",
          record_id: company.id,
          subject_name: company.name,
          metadata: {
            source_company_id: source_company.id,
            historical_import_batch_id: batch.id,
            copy_summary: preview.fetch(:copy_summary)
          }
        )
      end
      Dispatch.call(company: company, actor: actor)
      company
    rescue ActiveRecord::RecordNotUnique
      raise ArgumentError, "Archive the existing migration rehearsal before creating another"
    end

    private

    attr_reader :source_company, :actor, :name, :acknowledgement, :batch

    def authorize!
      allowed = actor&.organization_admin? && actor.can_access_company?(source_company.id) &&
        StaffRolePolicy.allowed?(actor, :manage_organization)
      raise ArgumentError, "An organization administrator with access to this client is required" unless allowed
    end
  end
end
