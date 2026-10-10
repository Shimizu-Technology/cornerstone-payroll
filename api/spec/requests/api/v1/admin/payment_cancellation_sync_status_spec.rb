# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Per-item cancellation sync status", type: :request do
  let(:company) { create(:company, next_check_number: 8001) }
  let(:employee) { create(:employee, company: company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:item) do
    create(:payroll_item, :with_check, company: company, employee: employee, pay_period: period,
      check_number: "8000", payment_delivery_method: "paper_check", hours_worked: 5, overtime_hours: 1)
  end
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "aire_services",
      expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
      source_protocol_version: "1.0", identity_verified_at: Time.current,
      source_capabilities: TimeTracking::Connector::AIRE_CAPABILITIES + [ "payment_cancellation_v1" ])
  end
  let(:import) { create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source, status: "applied") }

  def direct_line(entry_id = "41")
    TimeTrackingEntryAllocation.create!(company: company, time_tracking_source: source,
      time_tracking_import: import, pay_period: period, payroll_item: item, employee: employee,
      source_user_id: "91", source_user_uuid: SecureRandom.uuid, source_time_entry_id: entry_id,
      line_key: "flight:#{entry_id}", source_kind: "current", original_work_date: period.start_date,
      total_hours: 6, regular_hours: 5, overtime_hours: 1)
  end

  def manual_line
    TimeTrackingManualAllocation.create!(company: company, time_tracking_source: source,
      pay_period: period, payroll_item: item, employee: employee, created_by: actor,
      source_user_uuid: SecureRandom.uuid, source_time_entry_id: "41", source_time_entry_version: 2,
      original_work_date: period.start_date, regular_hours: 5, overtime_hours: 1,
      reconciliation_note: "Synthetic exact committed source hours", status: "committed", remote_allocation_id: "501", remote_version: 0)
  end

  def cancel_paper
    item.mark_package_prepared!(user: actor)
    PayrollPaymentMethodService.new(payroll_item: item, actor: actor, method: "direct_deposit",
      reason: "Original instrument recovered and cancelled", confirm_not_paid: true,
      retire_existing_check: true, confirm_check_cancelled: true,
      cancellation_evidence_reference: "Synthetic bank stop payment 42", expected_check_number: "8000").call
  end

  def check_list
    get "/api/v1/admin/pay_periods/#{period.id}/checks", headers: { "X-Company-Id" => company.id.to_s }
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def statement_state
    check_list.fetch("earnings_statement_items").find { |row| row["id"] == item.id }.fetch("payment_cancellation_sync")
  end

  it "exposes pending direct cancellation on DD and statement rows without changing reserved hours or recording payment" do
    direct_line
    cancel_paper
    before = [ CheckEvent.count, AirePayrollEntryAcknowledgement.count, DirectDepositPaymentConfirmation.count, item.reload.attributes ]
    json = check_list
    state = json.fetch("direct_deposit_items").sole.fetch("payment_cancellation_sync")
    expect(state).to include("status" => "pending", "pending_count" => 1, "acknowledged_count" => 0, "hours_reserved" => true)
    expect(json.fetch("earnings_statement_items").sole.fetch("payment_cancellation_sync")).to eq(state)
    expect([ CheckEvent.count, AirePayrollEntryAcknowledgement.count, DirectDepositPaymentConfirmation.count, item.reload.attributes ]).to eq(before)
    expect(item).not_to be_voided
    expect(item.time_tracking_entry_allocations.sole.total_hours).to eq(6)
  end

  it "holds partial multi-line confirmation until every direct cancellation is delivered" do
    direct_line
    direct_line("42")
    cancel_paper
    acknowledgements = item.aire_payroll_entry_acknowledgements.where(status: "payment_cancelled").order(:id)
    acknowledgements.first.mark_delivered!(at: Time.current)
    expect(statement_state).to include("status" => "pending", "pending_count" => 1, "acknowledged_count" => 1)
    acknowledgements.last.mark_delivered!(at: Time.current)
    expect(statement_state).to include("status" => "acknowledged", "pending_count" => 0, "acknowledged_count" => 2, "oldest_pending_at" => nil)
  end

  it "shows only current undelivered errors, not stale errors on delivered receipts" do
    direct_line
    direct_line("42")
    cancel_paper
    acknowledgements = item.aire_payroll_entry_acknowledgements.where(status: "payment_cancelled").order(:id)
    acknowledgements.first.update!(delivered_at: Time.current, last_error: "Old retry failed")
    acknowledgements.last.record_delivery_failure!("Connected source unavailable")
    expect(statement_state).to include("status" => "error", "errors" => [ "Connected source unavailable" ])
  end

  it "keeps completed bank evidence alongside pending source cancellation and preserves causal delivery dependencies" do
    direct_line
    cancel_paper
    cancellation = item.aire_payroll_entry_acknowledgements.find_by!(status: "payment_cancelled")
    confirmation = DirectDepositPaymentConfirmation.create!(payroll_item: item, user: actor,
      settled_on: PayrollBusinessClock.today, bank_reference: "Synthetic completed replacement transfer")
    replacement = item.aire_payroll_entry_acknowledgements.find_by!(status: "payment_issued", payment_method: "direct_deposit")
    json = check_list
    expect(json["direct_deposit_items"].sole["payment_confirmation"]["bank_reference"]).to eq(confirmation.bank_reference)
    expect(json["direct_deposit_items"].sole["payment_cancellation_sync"]["status"]).to eq("pending")
    expect(replacement.delivery_dependencies).to include(cancellation.id)
  end

  it "exposes a manual pending intent and actual matching acknowledgement without adopting the old issued flag" do
    allocation = manual_line
    cancel_paper
    allocation.update!(status: "issued", last_sync_error: "Cancellation needs producer confirmation")
    expect(statement_state).to include("status" => "error", "pending_count" => 1, "hours_reserved" => true)
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:for_payroll_actor).and_return(client)
    allow(client).to receive(:cancel_payroll_manual_allocation_payment) do |**request|
      { "command" => { "id" => request.fetch(:command_id), "replayed" => false }, "manual_allocation" => {
        "id" => "501", "version" => 1, "status" => "committed",
        "source_time_entry_id" => allocation.source_time_entry_id,
        "source_time_entry_version" => allocation.source_time_entry_version,
        "source_user_uuid" => allocation.source_user_uuid, "work_date" => allocation.original_work_date.iso8601,
        "regular_hours" => allocation.regular_hours.to_s("F"), "overtime_hours" => allocation.overtime_hours.to_s("F"),
        "external_pay_period_id" => period.id.to_s, "external_payroll_item_id" => item.id.to_s,
        "cancelled_payment" => request.slice(:payment_method, :payment_reference, :payment_effective_on,
          :cancellation_evidence_reference, :reason, :occurred_at).stringify_keys.merge(
            "event_id" => "source-cancellation-event", "event_type" => "payment_cancelled")
      } }
    end
    TimeTracking::ManualAllocationService.new(pay_period: period, source: source, actor: actor).sync!(allocation, raise_on_failure: true)
    expect(statement_state).to include("status" => "acknowledged", "pending_count" => 0)
  end

  it "does not invent source sync for an unlinked retired instrument or an unrelated item" do
    cancel_paper
    expect(statement_state).to be_nil
    other_employee = create(:employee, company: company)
    other = create(:payroll_item, :with_check, company: company, employee: other_employee, pay_period: period, check_number: "8009")
    expect(check_list.fetch("checks").find { |row| row["id"] == other.id }.fetch("payment_cancellation_sync")).to be_nil
  end

  it "never exposes the item through another company context" do
    direct_line
    cancel_paper
    other = create(:company)
    actor.update!(role: "super_admin")
    get "/api/v1/admin/pay_periods/#{period.id}/checks", headers: { "X-Company-Id" => other.id.to_s }
    expect(response).to have_http_status(:not_found)
  end
end
