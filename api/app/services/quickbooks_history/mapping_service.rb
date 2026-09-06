# frozen_string_literal: true

module QuickbooksHistory
  class MappingService
    def initialize(worker:, employee:, actor:, archive_only: false)
      @worker = worker
      @employee = employee
      @actor = actor
      @archive_only = archive_only
    end

    def call
      ensure_authorized_actor!
      if archive_only && employee.present?
        raise ArgumentError, "Choose either a live employee or archive-only, not both"
      end
      unless archive_only || employee.present?
        raise ArgumentError, "Choose a live employee or mark the QuickBooks worker as archive-only"
      end
      if employee.present? && employee.company_id != worker.company_id
        raise ArgumentError, "Employee must belong to the same company"
      end

      HistoricalWorker.transaction do
        worker.historical_import_batch.lock!
        worker.lock!
        raise ArgumentError, "Locked historical worker mappings cannot be changed" if worker.historical_import_batch.locked?

        if archive_only
          worker.update!(employee: nil, mapping_status: "archive_only", match_method: "archive_only", match_confidence: nil)
          worker.historical_paychecks.update_all(employee_id: nil, updated_at: Time.current)
        else
          worker.update!(employee: employee, mapping_status: "manual_match", match_method: "manual", match_confidence: 1)
          worker.historical_paychecks.update_all(employee_id: employee.id, updated_at: Time.current)
        end
      end
      worker
    end

    private

    attr_reader :worker, :employee, :actor, :archive_only

    def ensure_authorized_actor!
      authorized = actor.present? &&
        actor.can_access_company?(worker.company_id) &&
        StaffRolePolicy.allowed?(actor, :manage_client_configuration)
      return if authorized

      raise ArgumentError, "An attributed manager or administrator with company access is required"
    end
  end
end
