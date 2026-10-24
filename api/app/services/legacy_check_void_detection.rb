# frozen_string_literal: true

# Review candidates only: no backfill or inferred accounting repair.
class LegacyCheckVoidDetection
  def self.items
    PayrollItem.financially_reportable.joins(:pay_period)
      .where(pay_periods: { status: "committed" }, payroll_items: { voided: true })
      .where(id: CheckEvent.where(event_type: "voided")
        .where("COALESCE(details ->> 'payroll_obligation_retained', '') <> 'true'")
        .select(:payroll_item_id))
      .where.not(id: PayrollLiabilityPosting.where(posting_type: "paycheck_reversal")
        .where("metadata ? 'payroll_item_id'").select(Arel.sql("(metadata ->> 'payroll_item_id')::bigint")))
  end
end
