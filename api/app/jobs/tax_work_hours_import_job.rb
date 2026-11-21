# frozen_string_literal: true

# Runs one queued "Refresh hours from Tax" import. Retries for slow or
# flaky responses happen inside TaxWorkHours::Client; a failed import keeps
# its plain-language reason and leaves the stored hours unchanged.
class TaxWorkHoursImportJob < ApplicationJob
  queue_as :default

  def perform(import_id)
    import = WorkHourImport.find_by(id: import_id)
    return unless import&.status == "queued"

    TaxWorkHours::Importer.call(import)
  end
end
