# frozen_string_literal: true

module MigrationRehearsal
  class Retry
    def initialize(company:, actor:)
      @company = company
      @actor = actor
    end

    def call
      authorize!
      Company.transaction do
        company.lock!
        unless company.migration_rehearsal_status == "failed"
          raise ArgumentError, "Only a failed migration rehearsal can be retried"
        end
        raise ArgumentError, "The source import is no longer locked" unless company.migration_source_batch&.locked?

        company.update!(
          migration_rehearsal_status: "pending",
          migration_rehearsal_error: nil,
          migration_rehearsal_completed_at: nil
        )
        AuditLog.record!(
          user: actor,
          organization_id: company.organization_id,
          company_id: company.id,
          action: "migration_rehearsal#retry",
          record_type: "companies",
          record_id: company.id,
          subject_name: company.name,
          metadata: {
            source_company_id: company.migration_source_company_id,
            source_historical_import_batch_id: company.migration_source_batch_id
          }
        )
      end
      Dispatch.call(company: company, actor: actor)
      company
    end

    private

    attr_reader :company, :actor

    def authorize!
      allowed = actor&.organization_admin? && actor.can_access_company?(company.id) &&
        StaffRolePolicy.allowed?(actor, :manage_organization)
      raise ArgumentError, "An organization administrator with access to this rehearsal is required" unless allowed
      raise ArgumentError, "Target must be a migration rehearsal" unless company.migration_rehearsal?
    end
  end
end
