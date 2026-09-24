# frozen_string_literal: true

module TestWorkspace
  class Dispatch
    def self.call(company:, actor:)
      CloneJob.perform_later(company.id, actor.id)
    rescue StandardError => e
      message = "The test workspace copy could not be queued. Retry when background processing is available."
      company.update_columns(migration_rehearsal_status: "failed", migration_rehearsal_error: message, updated_at: Time.current)
      AuditLog.record!(
        user: actor,
        organization_id: company.organization_id,
        company_id: company.id,
        action: "test_workspace#dispatch_failed",
        record_type: "companies",
        record_id: company.id,
        subject_name: company.name,
        metadata: { source_company_id: company.migration_source_company_id, error_class: e.class.name }
      )
      raise ArgumentError, message
    end

    private_class_method :new
  end
end
