# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollEntryAcknowledgement do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:uuid) { SecureRandom.uuid }

  def add_entry(item:, import:, entry_id:)
    TimeTrackingEntryAllocation.create!(
      company: company, time_tracking_source: source, time_tracking_import: import,
      pay_period: period, payroll_item: item, employee: employee,
      source_user_id: "42", source_user_uuid: uuid, source_time_entry_id: entry_id,
      line_key: "regular", source_kind: "current", original_work_date: period.start_date,
      total_hours: 1, regular_hours: 1, overtime_hours: 0
    )
  end

  it "does not create impossible batch acknowledgements for a live pre-pay snapshot" do
    item = create(:payroll_item, pay_period: period, employee: employee,
      payment_delivery_method: "direct_deposit", check_number: nil, gross_pay: 100, net_pay: 80)
    live = create(:time_tracking_import, pay_period: period, time_tracking_source: source,
      processed_payload: { "validation_version" => TimeTracking::LiveSnapshotPreviewService::VALIDATION_VERSION })
    add_entry(item: item, import: live, entry_id: "101")

    item.create_direct_deposit_payment_confirmation!(
      user: actor, settled_on: PayrollBusinessClock.today, bank_reference: "BANK-TEST-101"
    )

    expect(described_class.where(payroll_item: item)).to be_empty
  end

  it "creates a payment-issued entry acknowledgement for a finalized AIRE batch" do
    item = create(:payroll_item, pay_period: period, employee: employee,
      payment_delivery_method: "direct_deposit", check_number: nil, gross_pay: 100, net_pay: 80)
    locked = create(:time_tracking_import, :finalized_aire_batch,
      pay_period: period, time_tracking_source: source)
    add_entry(item: item, import: locked, entry_id: "202")

    item.create_direct_deposit_payment_confirmation!(
      user: actor, settled_on: PayrollBusinessClock.today, bank_reference: "BANK-TEST-202"
    )

    expect(described_class.where(payroll_item: item).pluck(:source_time_entry_id, :status, :payment_method, :payment_reference))
      .to eq([ [ "202", "payment_issued", "direct_deposit", "BANK-TEST-202" ] ])
  end
end
