# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeVerificationItems::RespondService do
  let(:organization) { create(:organization, name: "Harborview Org") }
  let(:company) { create(:company, organization: organization, name: "Harborview Bistro") }
  let(:client_manager) { create(:user, company: company, organization: organization, role: "client", name: "Sloane Owner") }
  let(:staff_manager) { create(:user, company: company, organization: organization, role: "manager", name: "Morgan Staff") }
  let(:employee) { create(:employee, :hourly, company: company, first_name: "Casey", last_name: "Worker") }

  before do
    stub_const("CompanyFeatures::LOCKED_OFF", CompanyFeatures::LOCKED_OFF - [ "client_portal.employee_lifecycle_mode" ])
    ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
        client_portal_enabled: true,
        options: { "client_portal" => { "employee_lifecycle_mode" => "client_managed" } },
        lifecycle_mode_activated_at: Time.current
      )
    )
  end

  it "resubmits an unacknowledged returned item in place, invokes on_company_locked inside the lock, and writes an audit log" do
    item = EmployeeVerificationItem.create!(
      company: company,
      employee: employee,
      event_kind: "compensation_change",
      status: "returned_to_client",
      affects_pay: true,
      changed_fields: [ "pay_rate" ],
      returned_by: staff_manager,
      returned_at: 1.hour.ago,
      return_note: "Verify rate"
    )
    lock_hook_called = false
    expect(PortalNotifications).to receive(:employee_verification_queued!).with(item).and_call_original

    result = described_class.call(
      company: company,
      actor: client_manager,
      item_id: item.id,
      note: "Confirmed against offer letter",
      expected_lifecycle_mode: "client_managed",
      on_company_locked: -> { lock_hook_called = true }
    )

    expect(result).to be_success
    expect(lock_hook_called).to be(true)
    expect(result.item.id).to eq(item.id)
    expect(result.item.status).to eq("pending_verification")
    expect(result.item.metadata["client_response_note"]).to eq("Confirmed against offer letter")
    expect(AuditLog.where(company_id: company.id, action: "employee_verification_items#respond", record_id: item.id)).to exist
  end

  it "creates a linked replacement for an acknowledged item and reuses it on repeated responses" do
    committed_period = create(:pay_period, company: company, status: "committed", start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
    ack_item = EmployeeVerificationItem.create!(
      company: company,
      employee: employee,
      event_kind: "compensation_change",
      status: "returned_to_client",
      affects_pay: true,
      changed_fields: [ "pay_rate" ],
      returned_by: staff_manager,
      returned_at: 1.hour.ago,
      return_note: "Verify rate"
    )
    PayPeriodVerificationAcknowledgement.create!(
      company: company,
      pay_period: committed_period,
      employee_verification_item: ack_item,
      employee: employee,
      acknowledged_by: staff_manager,
      acknowledged_at: Time.current,
      item_status_snapshot: ack_item.status,
      item_updated_at_snapshot: ack_item.updated_at
    )

    first = described_class.call(company: company, actor: client_manager, item_id: ack_item.id, note: "First note")
    second = described_class.call(company: company, actor: client_manager, item_id: ack_item.id, note: "Second note")

    expect(first).to be_success
    expect(second).to be_success
    expect(first.item.id).not_to eq(ack_item.id)
    expect(second.item.id).to eq(first.item.id)
    expect(second.item.metadata["client_response_note"]).to eq("First note\n\nSecond note")
    expect(ack_item.reload.status).to eq("returned_to_client")
  end

  it "returns conflict when expected_lifecycle_mode differs from current mode and unprocessable_entity when item is not returned" do
    item = EmployeeVerificationItem.create!(
      company: company,
      employee: employee,
      event_kind: "new_hire",
      status: "pending_verification",
      affects_pay: true
    )

    conflict = described_class.call(
      company: company,
      actor: client_manager,
      item_id: item.id,
      note: "Mode flipped",
      expected_lifecycle_mode: "approval_first"
    )
    expect(conflict).not_to be_success
    expect(conflict.status).to eq(:conflict)
    expect(conflict.code).to eq("lifecycle_mode_changed")

    invalid_status = described_class.call(
      company: company,
      actor: client_manager,
      item_id: item.id,
      note: "Already pending",
      expected_lifecycle_mode: "client_managed"
    )
    expect(invalid_status).not_to be_success
    expect(invalid_status.status).to eq(:unprocessable_entity)
  end
end
