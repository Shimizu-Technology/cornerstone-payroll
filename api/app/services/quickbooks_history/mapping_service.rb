# frozen_string_literal: true

module QuickbooksHistory
  class MappingService
    def initialize(worker:, employee:, actor:)
      @worker = worker
      @employee = employee
      @actor = actor
    end

    def call
      raise ArgumentError, "Locked historical worker mappings cannot be changed" if worker.historical_import_batch.locked?
      raise ArgumentError, "Employee must belong to the same company" unless employee.company_id == worker.company_id

      HistoricalWorker.transaction do
        worker.update!(employee: employee, match_method: "manual", match_confidence: 1)
        worker.historical_paychecks.update_all(employee_id: employee.id, updated_at: Time.current)
      end
      worker
    end

    private

    attr_reader :worker, :employee, :actor
  end
end
