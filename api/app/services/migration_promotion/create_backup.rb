# frozen_string_literal: true

module MigrationPromotion
  class CreateBackup
    ACKNOWLEDGEMENT = "CREATE READ-ONLY BACKUP"

    def initialize(rehearsal:, actor:, acknowledgement:)
      @rehearsal = rehearsal
      @target_company = rehearsal.migration_source_company
      @actor = actor
      @acknowledgement = acknowledgement
    end

    def call
      authorize!
      raise ArgumentError, "Confirm creation of the read-only backup" unless acknowledgement == ACKNOWLEDGEMENT

      preview = Preview.new(rehearsal: rehearsal)
      payload = preview.call
      raise ArgumentError, payload.fetch(:blockers).join("; ") unless payload.fetch(:ready_to_back_up)

      fingerprint = TargetFingerprint.call(target_company)
      backup = Company.new(target_company.attributes.slice(*MigrationRehearsal::Create::COMPANY_FIELDS).merge(
        name: backup_name,
        organization: target_company.organization,
        active: true,
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "backup_snapshot",
        migration_source_company: target_company,
        migration_source_batch: rehearsal.migration_source_batch,
        migration_rehearsal_status: "pending",
        migration_rehearsal_created_by: actor,
        migration_rehearsal_created_at: Time.current,
        migration_rehearsal_error: nil,
        test_workspace_manifest: {
          version: 1,
          purpose: "pre_promotion_backup",
          source_company_id: target_company.id,
          promotion_source_rehearsal_id: rehearsal.id,
          source_fingerprint: fingerprint,
          source_draft_pay_period_ids: target_company.pay_periods.draft.order(:id).pluck(:id)
        },
        test_workspace_expires_at: nil,
        test_workspace_sealed_at: nil,
        active_printer_profile_id: nil,
        auto_create_fit_check: false,
        payroll_intake_source_types: []
      ))

      Company.transaction do
        Company.lock.where(id: [ rehearsal.id, target_company.id ]).order(:id).load
        rehearsal.reload
        target_company.reload
        locked_preview = Preview.new(rehearsal: rehearsal)
        locked_payload = locked_preview.call
        unless locked_payload.fetch(:ready_to_back_up)
          raise ArgumentError, locked_payload.fetch(:blockers).join("; ")
        end

        existing = locked_preview.promotion_backup
        if existing&.migration_rehearsal_status == "pending"
          raise ArgumentError, "A promotion backup is already being prepared"
        end
        if existing&.migration_rehearsal_status == "ready" && existing.test_workspace_sealed_at.present? &&
            existing.test_workspace_manifest["source_fingerprint"] == fingerprint
          raise ArgumentError, "A current promotion backup already exists for this rehearsal"
        end
        raise ArgumentError, "The clean client changed while the backup was being prepared" unless fingerprint == TargetFingerprint.call(target_company)

        archived_at = Time.current
        other_active_backups = target_company.test_workspaces.where(
          test_workspace_purpose: "backup_snapshot",
          active: true,
          test_workspace_archived_at: nil
        )
        other_active_backups = other_active_backups.where.not(id: existing.id) if existing
        other_active_backups.update_all(active: false, test_workspace_archived_at: archived_at, updated_at: archived_at)
        existing&.update!(active: false, test_workspace_archived_at: archived_at)
        backup.save!
        AuditLog.record!(
          user: actor,
          organization_id: backup.organization_id,
          company_id: backup.id,
          action: "migration_promotion#backup_created",
          record_type: "companies",
          record_id: backup.id,
          subject_name: backup.name,
          metadata: {
            source_company_id: target_company.id,
            rehearsal_company_id: rehearsal.id,
            source_fingerprint: fingerprint
          }
        )
      end

      MigrationRehearsal::Dispatch.call(company: backup, actor: actor)
      backup
    end

    private

    attr_reader :rehearsal, :target_company, :actor, :acknowledgement

    def authorize!
      allowed = actor&.organization_admin? && actor.can_access_company?(rehearsal.id) &&
        actor.can_access_company?(target_company&.id) && StaffRolePolicy.allowed?(actor, :manage_organization)
      raise ArgumentError, "An organization administrator with access to both clients is required" unless allowed
    end

    def backup_name
      "#{target_company.name} — Backup before rehearsal #{Time.current.strftime('%Y-%m-%d %H%M')}"
    end
  end
end
