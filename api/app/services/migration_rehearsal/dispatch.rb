# frozen_string_literal: true

module MigrationRehearsal
  class Dispatch
    def self.call(company:, actor:)
      CloneJob.perform_later(company.id, company.migration_source_batch_id, actor.id)
    rescue StandardError => e
      message = "The verified rehearsal copy could not be queued. Retry when background processing is available."
      company.update_columns(
        migration_rehearsal_status: "failed",
        migration_rehearsal_error: message,
        updated_at: Time.current
      )
      AuditLog.record!(
        user: actor,
        organization_id: company.organization_id,
        company_id: company.id,
        action: "migration_rehearsal#dispatch_failed",
        record_type: "companies",
        record_id: company.id,
        subject_name: company.name,
        metadata: {
          source_company_id: company.migration_source_company_id,
          source_historical_import_batch_id: company.migration_source_batch_id,
          error_class: e.class.name
        }
      )
      raise ArgumentError, message
    end

    private_class_method :new
  end
end
