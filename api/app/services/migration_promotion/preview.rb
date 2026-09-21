# frozen_string_literal: true

module MigrationPromotion
  class Preview
    PERIOD_COUNT = 2

    def initialize(rehearsal:)
      @rehearsal = rehearsal
      @target_company = rehearsal.migration_source_company
    end

    def call
      mapping = employee_mapping
      blockers = base_blockers + mapping.blockers
      backup = promotion_backup
      backup_status = backup&.migration_rehearsal_status
      backup_current = backup_ready_and_current?(backup)

      blockers << "Create and verify a read-only backup before applying rehearsal data" unless backup
      blockers << "Wait for the read-only backup to finish" if backup_status == "pending"
      blockers << "Retry or replace the failed read-only backup" if backup_status == "failed"
      blockers << "The clean client changed after the backup; create a fresh backup" if backup_status == "ready" && !backup_current

      {
        rehearsal: company_summary(rehearsal),
        target_company: target_company && company_summary(target_company),
        ready_to_back_up: base_blockers.empty? && mapping.ready? && backup_replaceable?(backup, backup_current),
        ready_to_apply: blockers.empty? && backup_current,
        blockers: blockers.uniq,
        warnings: warnings,
        employee_mapping: mapping.summary,
        source_periods: source_periods.map { |period| period_summary(period) },
        replaceable_drafts: replaceable_drafts.map { |period| period_summary(period) },
        backup: backup && company_summary(backup).merge(current: backup_current)
      }
    end

    def source_periods
      @source_periods ||= rehearsal.pay_periods
        .regular_cycle
        .where(status: %w[calculated approved])
        .period_chronological
        .to_a
    end

    def promotion_backup
      @promotion_backup ||= target_company&.test_workspaces
        &.where(test_workspace_purpose: "backup_snapshot", active: true, test_workspace_archived_at: nil)
        &.order(created_at: :desc)
        &.detect { |company| company.test_workspace_manifest["promotion_source_rehearsal_id"].to_i == rehearsal.id }
    end

    def employee_mapping
      @employee_mapping ||= if target_company
        EmployeeMapper.new(rehearsal: rehearsal).call
      else
        EmployeeMapper::Result.new(map: {}, new_employees: [], blockers: [ "The rehearsal no longer has a clean-client source" ])
      end
    end

    private

    attr_reader :rehearsal, :target_company

    def base_blockers
      @base_blockers ||= build_base_blockers
    end

    def build_base_blockers
      blockers = []
      blockers << "Choose a ready migration rehearsal" unless rehearsal.migration_rehearsal? && rehearsal.test_workspace_ready?
      blockers << "This rehearsal has already been applied" if rehearsal.test_workspace_manifest["promotion_status"] == "completed"
      blockers << "The rehearsal must point to a live clean client" unless target_company&.live_payroll?
      blockers << "Exactly two calculated or approved regular payrolls are required" unless source_periods.length == PERIOD_COUNT
      blockers << "The clean client already contains processed Cornerstone payroll" if target_company && target_company.pay_periods.where.not(status: "draft").exists?
      blockers << "The clean client's draft payroll contains entered payroll data" if target_company && target_company.payroll_items.exists?
      blockers << "The clean client contains an unrelated draft payroll" if unrelated_drafts.any?
      blockers << "One or more rehearsal payrolls were already promoted" if target_company &&
        target_company.pay_periods.where(promotion_source_pay_period_id: source_periods.map(&:id)).exists?
      blockers
    end

    def replaceable_drafts
      return PayPeriod.none unless target_company

      @replaceable_drafts ||= begin
        signatures = source_periods.map { |period| period_signature(period) }
        target_company.pay_periods.draft.select { |period| signatures.include?(period_signature(period)) }
      end
    end

    def unrelated_drafts
      return [] unless target_company

      target_company.pay_periods.draft.to_a - replaceable_drafts
    end

    def backup_ready_and_current?(backup)
      backup&.backup_snapshot? && backup.migration_rehearsal_status == "ready" && backup.test_workspace_sealed_at.present? &&
        backup.test_workspace_manifest["source_fingerprint"] == TargetFingerprint.call(target_company)
    end

    def backup_replaceable?(backup, backup_current)
      backup.blank? || backup.migration_rehearsal_status == "failed" ||
        (backup.migration_rehearsal_status == "ready" && !backup_current)
    end

    def period_signature(period)
      [ period.start_date, period.end_date, period.pay_date ]
    end

    def period_summary(period)
      {
        id: period.id,
        start_date: period.start_date,
        end_date: period.end_date,
        pay_date: period.pay_date,
        status: period.status,
        employee_count: period.payroll_items.not_voided.distinct.count(:employee_id),
        gross_pay: period.payroll_items.not_voided.sum(:gross_pay).to_d,
        net_pay: period.payroll_items.not_voided.sum(:net_pay).to_d
      }
    end

    def company_summary(company)
      {
        id: company.id,
        name: company.name,
        status: company.migration_rehearsal_status,
        employee_count: company.employees.count
      }
    end

    def warnings
      [
        "The backup is a sealed, read-only copy of the clean client and its locked historical archive.",
        "Applying replaces the clean client's employee setup and empty overlapping draft, then records the two rehearsal payrolls as migrated committed payroll.",
        "No checks are printed, payments sent, filings submitted, messages sent, or external payroll syncs started."
      ]
    end
  end
end
