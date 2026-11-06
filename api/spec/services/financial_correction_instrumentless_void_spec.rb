# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Source-backed instrumentless whole-payroll void" do
  include_context "exact source correction fixtures"
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "custom", remote_source_identifier: "fixture_time",
      expected_source_instance_id: instance_id, source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0",
      source_capabilities: %w[finalized_batch_v2 exact_line_receipts_v2 payroll_obligation_correction_v1], identity_verified_at: Time.current)
  end
  let(:original_item) do
    item = create(:payroll_item, company: company, employee: employee, pay_period: original_period,
      pay_rate: 25, hours_worked: 4, overtime_hours: 0, holiday_hours: 0, pto_hours: 0,
      custom_deductions: [ { label: "Mistaken one-time deduction", amount: 92.35 } ])
    item.calculate!
    original_period.update!(status: "calculated")
    lifecycle = PayPeriodLifecycleService.new(pay_period: original_period, actor: actor)
    lifecycle.approve!
    lifecycle.commit!
    item.reload
  end

  def void_original
    expect(original_item.net_pay).to eq(0)
    expect(original_item.check_number).to be_nil
    expect(original_item.check_events).to be_empty
    PayPeriodCorrectionService.void!(pay_period: original_period, actor: actor, reason: "Correct the mistaken zero-net deduction")
  end

  it "records the exact whole-void tombstone and reversals without inventing a paper instrument or cash event" do
    event = void_original
    expect(original_period.reload).to be_voided
    expect(original_item.reload).not_to be_voided # This field describes the check, which never existed.
    expect(original_item.check_events).to be_empty
    expect(original_item.check_number).to be_nil
    expect(EmployeeYtdTotal.find_by!(employee: employee, year: 2026).gross_pay).to eq(0)
    expect(original_period.payroll_liability_postings.source_postings).to all(be_reversed)
    ack = original_item.aire_payroll_entry_acknowledgements.find_by!(status: "payment_voided")
    expect(ack.source_time_entry_id).to eq(allocation.source_time_entry_id)
    expect(ack.source_line_key).to eq(allocation.line_key)
    expect(ack.source_event_key).to include(event.id.to_s)
    expect(ack.attributes.values_at("payment_method", "payment_reference", "payment_effective_on")).to eq([ nil, nil, nil ])
    expect { PayPeriodCorrectionService.void!(pay_period: original_period, actor: actor, reason: "Do not repeat the void") }.to raise_error(PayPeriodCorrectionService::AlreadyVoidedError)
    expect(original_item.aire_payroll_entry_acknowledgements.where(status: "payment_voided").count).to eq(1)
  end

  it "commits corrected unchanged work through the normal services using the actual instrumentless predecessor" do
    void_original
    period = PayPeriodCorrectionService.create_correction_run!(source_pay_period: original_period, actor: actor, reason: "Remove the mistaken deduction")
    item = period.payroll_items.first!
    item.update!(custom_deductions: [])
    item.calculate!
    period.update!(status: "calculated")
    lifecycle = PayPeriodLifecycleService.new(pay_period: period, actor: actor)
    lifecycle.approve!
    lifecycle.commit!
    expect(item.reload.gross_pay).to eq(100)
    expect(item.net_pay).to eq(92.35)
    link = item.time_tracking_financial_correction_links.first!
    expect(link.predecessor_payroll_item_id).to eq(original_item.id)
    expect(link.payload.dig("obligation_correction", "financial_assertion", "voided_pay_period_id")).to eq(original_period.id.to_s)
    expect { item.mark_package_prepared!(user: actor) }.to raise_error(ArgumentError, /Source/)
  end
  it "does not reinterpret retained check history as an instrumentless predecessor" do
    original_item.check_events.create!(user: actor, event_type: "assigned", check_number: "30000")
    PayPeriodCorrectionService.void!(pay_period: original_period, actor: actor, reason: "Review historical check ownership")
    expect(original_item.aire_payroll_entry_acknowledgements.where(status: "payment_voided")).to be_empty
    period = PayPeriodCorrectionService.create_correction_run!(source_pay_period: original_period, actor: actor, reason: "Review historical check ownership")
    item = period.payroll_items.first!
    item.update!(custom_deductions: [])
    item.calculate!
    period.update!(status: "calculated")
    lifecycle = PayPeriodLifecycleService.new(pay_period: period, actor: actor)
    lifecycle.approve!
    expect { lifecycle.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /prior whole payroll and check/)
    expect(period.reload.status).to eq("approved")
    expect(item.time_tracking_financial_correction_links).to be_empty
    expect(item.reload.check_number).to be_nil
  end
end
