# frozen_string_literal: true

# Runs one "Refresh hours from Tax" import. Retries for slow or flaky
# responses happen inside TaxWorkHours::Client; a failed import keeps its
# plain-language reason and leaves the stored hours unchanged.
#
# If the worker running an import dies, the import stays "running" until its
# lease ends. When Solid Queue runs this job again, it waits out the lease and
# then takes the import over (WorkHourImport#claim! lets exactly one worker in).
class TaxWorkHoursImportJob < ApplicationJob
  self.rls_mode = :exempt_tables_only

  class LeaseHeld < StandardError; end

  queue_as :default
  # A live worker kept the import the whole time: nothing for this run to do.
  retry_on LeaseHeld, wait: WorkHourImport::RUNNING_LEASE / 2, attempts: 4 do |_job, error|
    Rails.logger.info("[TaxWorkHours] #{error.message}; leaving it with that worker")
  end

  def perform(import_id)
    import = WorkHourImport.find_by(id: import_id)
    return unless import && import.status.in?(WorkHourImport::ACTIVE_STATUSES)
    raise LeaseHeld, "import #{import.id} is held by another worker" if import.lease_remaining

    TaxWorkHours::Importer.call(import)
  end
end
