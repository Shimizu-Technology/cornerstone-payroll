# frozen_string_literal: true

module MigrationRehearsal
  class Preview
    def initialize(source_company:, batch: nil)
      @source_company = source_company
      @batch = batch || source_company.historical_import_batches.where(status: "locked").recent_first.first
    end

    def call
      blockers = []
      blockers << "Choose a live client as the rehearsal source" unless source_company.live_payroll?
      blockers << "Lock a verified historical import before creating a rehearsal" unless batch&.locked?
      blockers << "Verify every retained QuickBooks source file before creating a rehearsal" if batch && !batch.source_files_complete_and_verified?
      blockers << "Archive the existing migration rehearsal before creating another" if active_rehearsal

      {
        source_company: { id: source_company.id, name: source_company.name },
        historical_import_batch_id: batch&.id,
        ready: blockers.empty?,
        blockers: blockers,
        warnings: warnings,
        existing_rehearsal: active_rehearsal && company_summary(active_rehearsal),
        copy_summary: copy_summary
      }
    end

    private

    attr_reader :source_company, :batch

    def active_rehearsal
      @active_rehearsal ||= source_company.migration_rehearsals.active.order(created_at: :desc).first
    end

    def warnings
      values = [
        "This copies protected employee and payroll data inside the same Cornerstone organization.",
        "Client portal users, invitations, messages, documents, paid Cornerstone payroll, checks, filings, and audit history are not copied.",
        "External time-tracking and payroll-intake connections, client communications, and payroll reminders are not copied.",
        "Every rehearsal payroll is forced to parallel mode and cannot be committed. Official filing, payment, and check actions are blocked."
      ]
      values << "#{source_company.pay_periods.committed.count} committed Cornerstone pay period(s) will not be copied." if source_company.pay_periods.committed.exists?
      values
    end

    def copy_summary
      return {} unless batch

      {
        employees: source_company.employees.count,
        active_employees: source_company.employees.active.count,
        imported_pay_periods: batch.historical_pay_periods.count,
        imported_paychecks: batch.historical_paychecks.count,
        retained_source_files: batch.historical_import_source_files.count,
        source_file_bytes: batch.historical_import_source_files.sum(:byte_size),
        historical_adjustments: HistoricalPaycheckAdjustment.where(historical_paycheck_id: batch.historical_paychecks.select(:id)).count,
        ytd_balance_rows: HistoricalEmployeeYtdBalance.where(historical_ytd_bridge_id: batch.historical_ytd_bridges.select(:id)).count
      }
    end

    def company_summary(company)
      {
        id: company.id,
        name: company.name,
        status: company.migration_rehearsal_status
      }
    end
  end
end
