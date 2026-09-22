# frozen_string_literal: true

module TestWorkspace
  class Lifecycle
    RESTORE_EXPIRATION_DAYS = 90

    def initialize(company:, actor:)
      @company = company
      @actor = actor
    end

    def archive!
      authorize!
      raise ArgumentError, "Read-only backup snapshots cannot be archived manually" if company.backup_snapshot?
      raise ArgumentError, "This test workspace is already archived" if company.test_workspace_archived_at.present?

      timestamp = Time.current
      company.update!(active: false, test_workspace_archived_at: timestamp)
      audit!("test_workspace#archive", archived_at: timestamp)
      company
    end

    def restore!
      authorize!
      raise ArgumentError, "Read-only backup snapshots cannot be restored manually" if company.backup_snapshot?
      unless company.test_workspace_archived_at.present? || company.test_workspace_expired?
        raise ArgumentError, "This test workspace is neither archived nor expired"
      end
      raise ArgumentError, "Sealed test workspaces cannot be restored" if company.test_workspace_sealed_at.present?

      was_archived = company.test_workspace_archived_at.present?
      was_expired = company.test_workspace_expired?
      expiration = company.test_workspace_expires_at.present? ? RESTORE_EXPIRATION_DAYS.days.from_now : nil
      Company.transaction do
        company.lock!
        company.update!(active: true, test_workspace_archived_at: nil, test_workspace_expires_at: expiration)
        company.company_assignments.update_all(expires_at: expiration, updated_at: Time.current) if expiration
        audit!("test_workspace#restore", expires_at: expiration, was_archived: was_archived, was_expired: was_expired)
      end
      company
    rescue ActiveRecord::RecordNotUnique
      raise ArgumentError, "Archive the other active workspace of this type before restoring this one"
    end

    private

    attr_reader :company, :actor

    def authorize!
      allowed = company&.test_workspace? && actor&.organization_admin? &&
        actor.organization_id == company.organization_id && StaffRolePolicy.allowed?(actor, :manage_organization)
      raise ArgumentError, "An organization administrator is required" unless allowed
    end

    def audit!(action, metadata)
      AuditLog.record!(
        user: actor,
        organization_id: company.organization_id,
        company_id: company.id,
        action: action,
        record_type: "companies",
        record_id: company.id,
        subject_name: company.name,
        metadata: metadata
      )
    end
  end
end
