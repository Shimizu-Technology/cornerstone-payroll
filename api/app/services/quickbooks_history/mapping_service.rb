# frozen_string_literal: true

module QuickbooksHistory
  class MappingService
    def initialize(worker:, employee:, actor:)
      @worker = worker
      @employee = employee
      @actor = actor
    end

    def call
      ensure_authorized_actor!
      raise ArgumentError, "Employee must belong to the same company" unless employee.company_id == worker.company_id

      HistoricalWorker.transaction do
        worker.historical_import_batch.lock!
        worker.lock!
        raise ArgumentError, "Locked historical worker mappings cannot be changed" if worker.historical_import_batch.locked?

        worker.update!(employee: employee, match_method: "manual", match_confidence: 1)
        worker.historical_paychecks.update_all(employee_id: employee.id, updated_at: Time.current)
      end
      worker
    end

    private

    attr_reader :worker, :employee, :actor

    def ensure_authorized_actor!
      authorized = actor.present? &&
        actor.can_access_company?(worker.company_id) &&
        StaffRolePolicy.allowed?(actor, :manage_client_configuration)
      return if authorized

      raise ArgumentError, "An attributed manager or administrator with company access is required"
    end
  end
end
