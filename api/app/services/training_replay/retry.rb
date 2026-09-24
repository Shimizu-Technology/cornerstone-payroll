# frozen_string_literal: true

module TrainingReplay
  class Retry
    def initialize(company:, actor:)
      @company = company
      @actor = actor
    end

    def call
      authorize!
      Company.transaction do
        company.lock!
        raise ArgumentError, "Only a failed training replay can be retried" unless company.migration_rehearsal_status == "failed"
        raise ArgumentError, "Remove the incomplete training data before retrying" if company.pay_periods.exists? || company.employees.exists?

        company.update!(
          migration_rehearsal_status: "pending",
          migration_rehearsal_error: nil,
          migration_rehearsal_completed_at: nil
        )
        AuditLog.record!(
          user: actor,
          organization_id: company.organization_id,
          company_id: company.id,
          action: "training_replay#retry",
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
      raise ArgumentError, "An organization administrator with access to this training workspace is required" unless allowed
      raise ArgumentError, "Target must be a training replay" unless company.training_replay?
    end
  end
end
