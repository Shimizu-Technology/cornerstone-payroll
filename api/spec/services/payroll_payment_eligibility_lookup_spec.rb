# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollPaymentEligibilityLookup do
  let(:period) { build_detail_read_period(ordinary_rows: 4) }
  let(:items) do
    period.payroll_items.includes(:time_tracking_entry_allocations, :check_events, :check_reconciliation_events).to_a
  end
  let(:lookup) { described_class.new(items) }

  it "answers each question exactly as the row's own query does" do
    items.each do |item|
      manual = item.time_tracking_manual_allocations
      expect(lookup.duplicate_check_linked?(item)).to eq(item.duplicate_check_linked?), "duplicate #{item.id}"
      expect(lookup.source_accounting_correction_linked?(item)).to eq(item.source_accounting_correction_linked?), "accounting #{item.id}"
      expect(lookup.pending_payment_resolution?(item)).to eq(manual.pending_payment_resolution.exists?), "resolution #{item.id}"
      expect(lookup.manual_payment_activity?(item)).to eq(manual.with_payment_activity.exists?), "activity #{item.id}"
      expect(lookup.manual_cancellation_intent?(item)).to eq(manual.with_payment_cancellation_intent.exists?), "cancellation #{item.id}"
      expect(lookup.active_manual_allocations(item)).to match_array(manual.not_voided.to_a), "manual #{item.id}"
      expected_lines = item.time_tracking_entry_allocations.to_a + TimeTracking::FinancialCorrectionService.links_for(item)
      expect(lookup.source_lines(item)).to match_array(expected_lines), "lines #{item.id}"
      expected_lines.each do |row|
        expect(lookup.original_receipt(item, row, item.check_number))
          .to eq(TimeTracking::PaymentCancellationBridge.original_receipt(item, row, item.check_number)), "receipt #{item.id}"
      end
    end
  end

  it "returns the same eligibility for each row as the unbatched check" do
    activity = PayrollPaymentMethodEligibility.print_activity_for_period(period)
    items.each do |item|
      expect(PayrollPaymentMethodEligibility.new(item, print_activity: activity, lookup: lookup).call)
        .to eq(PayrollPaymentMethodEligibility.new(item, print_activity: activity).call)
      expect(TimeTracking::PaymentCancellationBridge.blocker_for(item, lookup: lookup))
        .to eq(TimeTracking::PaymentCancellationBridge.blocker_for(item))
    end
  end

  it "keeps a blocked receipt blocked when an older receipt was valid but the latest is not" do
    receipts = AirePayrollEntryAcknowledgement.where(payroll_item_id: items.map(&:id), status: "payment_issued")
    item = items.find { |row| receipts.exists?(payroll_item_id: row.id) && !TimeTracking::PaymentCancellationBridge.blocker_for(row).nil? }
    line = item.time_tracking_entry_allocations.first

    expect(lookup.original_receipt(item, line, item.check_number)).to have_attributes(status: "payment_issued")
    expect(TimeTracking::PaymentCancellationBridge.blocker_for(item, lookup: lookup)).to match(/receipt is missing/)
  end
end
