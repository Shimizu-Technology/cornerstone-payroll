# frozen_string_literal: true

module QuickbooksHistory
  class LifecycleService
    ACKNOWLEDGEMENT = "I understand this imports authoritative QuickBooks snapshots and does not recalculate payroll."

    def initialize(batch:, actor:)
      @batch = batch
      @actor = actor
    end

    def apply!(acknowledgement:)
      batch.with_lock do
        return batch if batch.applied? || batch.locked?
        raise ArgumentError, "Only a previewed historical import can be applied" unless batch.previewed?
        raise ArgumentError, "Resolve every reconciliation error before applying" if batch.blocking_errors?
        raise ArgumentError, "Confirm the authoritative snapshot acknowledgement" unless acknowledgement.to_s == ACKNOWLEDGEMENT

        verify_preview_totals!
        ensure_no_applied_duplicates!
        batch.update!(
          status: "applied",
          applied_by: actor,
          applied_at: Time.current,
          apply_acknowledgement: acknowledgement
        )
      end
      batch
    end

    def lock!
      batch.with_lock do
        return batch if batch.locked?
        raise ArgumentError, "Apply the historical import before locking it" unless batch.applied?
        raise ArgumentError, "Reconciliation must pass before the historical import can be locked" unless batch.reconciliation_summary.to_h["passed"] == true
        raise ArgumentError, "Every non-summary paycheck must reconcile before locking" if batch.historical_paychecks.where(reconciliation_status: "unmatched").exists?

        verify_preview_totals!
        batch.update!(status: "locked", locked_by: actor, locked_at: Time.current)
      end
      batch
    end

    private

    attr_reader :batch, :actor

    def verify_preview_totals!
      expected = batch.preview_summary.to_h
      raise ArgumentError, "Preview paycheck count no longer matches staged history" unless expected.fetch("paycheck_count").to_i == batch.historical_paychecks.count
      raise ArgumentError, "Preview period count no longer matches staged history" unless expected.fetch("period_count").to_i == batch.historical_pay_periods.count
      raise ArgumentError, "Preview worker count no longer matches staged history" unless expected.fetch("worker_count").to_i == batch.historical_workers.count

      expected_totals = expected.fetch("totals", {})
      ImportService::MONEY_FIELDS.each do |field|
        actual = batch.historical_paychecks.sum(field).to_d.round(2)
        expected_value = BigDecimal(expected_totals.fetch(field.to_s, "0")).round(2)
        raise ArgumentError, "Preview #{field.to_s.humanize.downcase} no longer matches staged history" unless actual == expected_value
      end
    end

    def ensure_no_applied_duplicates!
      keys = batch.historical_paychecks.pluck(:external_key)
      duplicate = HistoricalPaycheck.joins(:historical_import_batch)
                                    .where(company_id: batch.company_id, external_key: keys)
                                    .where.not(historical_import_batch_id: batch.id)
                                    .merge(HistoricalImportBatch.visible_history)
                                    .exists?
      raise ArgumentError, "One or more paycheck snapshots already exist in applied QuickBooks history" if duplicate
    end
  end
end
