# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::ManualAllocationReceiptPresenter do
  let(:source) { instance_double(TimeTrackingSource, id: 7) }
  let(:allocation) do
    instance_double(TimeTrackingManualAllocation, time_tracking_source_id: 7,
      remote_allocation_id: "501", pay_period_id: 8, payroll_item_id: 9,
      source_time_entry_id: "41", source_user_uuid: "stable-person-uuid",
      original_work_date: Date.new(2026, 9, 4), regular_hours: BigDecimal("4"), overtime_hours: BigDecimal("0"))
  end
  let(:receipt) do
    { "id" => "501", "external_pay_period_id" => "8", "external_payroll_item_id" => "9",
      "source_time_entry_id" => "41", "source_user_uuid" => "stable-person-uuid",
      "original_work_date" => "2026-09-04", "regular_hours" => 4.0, "overtime_hours" => 0.0,
      "status" => "issued", "payment_reference" => "original-check-1234", "payment_effective_on" => "2026-09-15" }
  end

  def present(rows)
    described_class.new(source: source, payload: { "manual_allocations" => rows }).call(allocation)
  end

  it "shows the immutable source issuance reference and date without consulting the current check or scheduled payday" do
    expect(present([ receipt ])).to eq(reference: "original-check-1234", effective_on: "2026-09-15", provenance: "aire_issued_receipt")
    expect(allocation).not_to receive(:payroll_item)
  end

  %w[id external_pay_period_id external_payroll_item_id source_time_entry_id source_user_uuid original_work_date regular_hours overtime_hours].each do |field|
    it "withholds another or changed allocation's receipt when #{field} differs" do
      receipt[field] = field.include?("hours") ? 1 : "other"
      expect(present([ receipt ])).to be_nil
    end
  end

  it "withholds a receipt from a different source installation" do
    allow(allocation).to receive(:time_tracking_source_id).and_return(99)
    expect(present([ receipt ])).to be_nil
  end

  it "withholds duplicate remote IDs instead of choosing an arbitrary receipt" do
    expect(present([ receipt, receipt.dup ])).to be_nil
  end

  it "withholds receipts for allocations which have not acknowledged a remote identity" do
    allow(allocation).to receive(:remote_allocation_id).and_return(nil)
    expect(present([ receipt ])).to be_nil
  end

  %w[committed voided pending_commit].each do |status|
    it "does not present #{status} as an issued source receipt" do
      receipt["status"] = status
      expect(present([ receipt ])).to be_nil
    end
  end

  [ nil, "", "   ", 1234, "x" * 201 ].each_with_index do |reference, index|
    it "withholds invalid or missing payment reference case #{index}" do
      receipt["payment_reference"] = reference
      expect(present([ receipt ])).to be_nil
    end
  end

  [ nil, "", "2026-02-30", "20260915", "2026-09-15T00:00:00Z" ].each_with_index do |date, index|
    it "withholds invalid or ambiguous issuance date case #{index}" do
      receipt["payment_effective_on"] = date
      expect(present([ receipt ])).to be_nil
    end
  end

  [ nil, "", "NaN", "Infinity", "4.001", true ].each_with_index do |hours, index|
    it "requires exact finite hours case #{index}" do
      receipt["regular_hours"] = hours
      expect(present([ receipt ])).to be_nil
    end
  end

  it "does not synthesize a receipt from missing or malformed source rows" do
    [ nil, [], {}, "unavailable", [ nil, "invalid" ] ].each do |rows|
      expect(present(rows)).to be_nil
    end
  end
end
