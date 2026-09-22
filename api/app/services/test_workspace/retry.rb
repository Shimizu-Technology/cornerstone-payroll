# frozen_string_literal: true

module TestWorkspace
  class Retry
    def initialize(company:, actor:)
      @company = company
      @actor = actor
    end

    def call
      authorize!
      Company.transaction do
        company.lock!
        raise ArgumentError, "Only a failed test workspace can be retried" unless company.migration_rehearsal_status == "failed"
        raise ArgumentError, "Remove the incomplete test data before retrying" if company.pay_periods.exists? || company.employees.exists?

        company.update!(
          migration_rehearsal_status: "pending",
          migration_rehearsal_error: nil,
          migration_rehearsal_completed_at: nil
        )
        AuditLog.record!(
          user: actor,
          organization_id: company.organization_id,
          company_id: company.id,
          action: "test_workspace#retry",
          record_type: "companies",
          record_id: company.id,
          subject_name: company.name,
          metadata: { source_company_id: company.migration_source_company_id }
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
      raise ArgumentError, "An organization administrator with access to this test workspace is required" unless allowed
      raise ArgumentError, "Target must be a general test workspace" unless company.sandbox?
    end
  end
end
