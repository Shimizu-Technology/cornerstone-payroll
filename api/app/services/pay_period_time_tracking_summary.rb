# frozen_string_literal: true

# Capabilities come from this client's saved source settings. Applied records
# remain available for audit after a source is disabled, without contacting it.
class PayPeriodTimeTrackingSummary
  def self.call(pay_period)
    imports = pay_period.time_tracking_imports
                        .joins(:time_tracking_source)
                        .where(status: "applied", time_tracking_sources: { company_id: pay_period.company_id })
                        .includes(:time_tracking_source, :time_tracking_entry_allocations, :aire_payroll_entry_acknowledgements)
                        .order(:id)
    summary = {
      active_source_types: pay_period.company.time_tracking_sources.active.distinct.pluck(:source_type),
      linked_aire_records: imports.select(&:finalized_batch?).map do |import|
        coverage = TimeTracking::CorrectionCoverage.new(import)
        {
          id: import.id,
          source_name: import.time_tracking_source.name,
          source_active: import.time_tracking_source.active?,
          external_batch_id: import.external_batch_id,
          external_batch_checksum: import.external_batch_checksum,
          contract_version: import.contract_version,
          source_cutoff_at: import.source_cutoff_at,
          applied_at: import.applied_at,
          reconciled_at: import.reconciled_at,
          reconciliation_note: import.reconciliation_note,
          reconciliation_exceptions: import.reconciliation_exceptions,
          payable_line_status: TimeTracking::AllocationStatusSummary.call(import, coverage: coverage),
          correction_dispositions: coverage.presentation,
          source_processing_status: import.source_processing_status,
          source_processing_synced_at: import.source_processing_synced_at
        }
      end
    }
    calendar = AirePayrollCalendar::Presenter.call(pay_period)
    summary[:aire_calendar] = calendar if calendar
    summary[:linked_source_records] = summary[:linked_aire_records]
    summary[:payroll_calendar] = summary[:aire_calendar] if summary[:aire_calendar]
    summary[:active_source_capabilities] = pay_period.company.time_tracking_sources.active.flat_map { |source| source.connector.capabilities }.uniq
    summary
  end
end
