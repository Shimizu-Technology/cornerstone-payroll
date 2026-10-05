# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::ConnectorHealth do
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services", active: false) }
  let(:period) { create(:pay_period, company: company) }
  let(:import) { create(:time_tracking_import, time_tracking_source: source, pay_period: period) }
  let(:now) { Time.utc(2026, 10, 6, 0) }
  def report
    described_class.new(source, now: now).call
  end

  it "keeps source-wide unknown counts distinct from an empty local queue without contacting the producer" do
    expect(TimeTracking::Client).not_to receive(:new)
    expect(report).to include(active: false, evidence_scope: "local_records")
    expect(report.dig(:receipts, :entry)).to include(recorded_count: 0, pending_count: 0, last_success_at: nil, oldest_pending_age_seconds: nil)
    expect(report[:source_settlement_holds]).to eq(status: "not_fetched", count: nil)
    expect(report[:source_roster_missing_mappings]).to eq(status: "not_fetched", count: nil)
    expect(report[:latest_import_mapping_review]).to eq(status: "not_recorded", missing_count: nil)
  end

  it "reports current undelivered queue age and keeps delivered historical failures out of active failed counts" do
    pending = AirePayrollAcknowledgement.record!(time_tracking_import: import, status: "committed", occurred_at: now - 2.days)
    pending.update_columns(created_at: now - 3.hours, last_error: "Bearer sensitive-token employee@example.test", updated_at: now - 1.hour)
    delivered = AirePayrollAcknowledgement.record!(time_tracking_import: import, status: "imported", occurred_at: now - 4.days)
    delivered.update_columns(delivered_at: now - 2.hours, last_error: "old error")
    result = report
    expect(result.dig(:receipts, :batch)).to include(recorded_count: 2, pending_count: 1, failed_count: 1,
      oldest_pending_age_seconds: 10_800, last_success_at: now - 2.hours, pay_period_ids: [ period.id ])
    expect(result.to_json).not_to match(/sensitive-token|employee@example|old error|shared_secret|base_url/)
  end

  it "ignores another company's records even when a historical import points at this source" do
    foreign_import = create(:time_tracking_import, time_tracking_source: source)
    AirePayrollAcknowledgement.record!(time_tracking_import: foreign_import, status: "committed", occurred_at: now)
    expect(report.dig(:receipts, :batch, :recorded_count)).to eq(0)
    expect(report[:latest_import_mapping_review][:status]).to eq("not_recorded")
  end

  it "reports only the latest revision per calendar period, retaining the last successful delivery" do
    calendar = create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: period)
    old = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, delivery_status: "failed")
    latest = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, schedule_version: 2, delivery_status: "delivered", delivered_at: now - 1.hour)
    expect(report[:calendar]).to include(unacknowledged_revision_count: 0, failed_revision_count: 0, last_success_at: latest.delivered_at)
    create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, schedule_version: 3,
      created_at: now - 30.minutes, delivery_status: "pending")
    expect(report[:calendar]).to include(unacknowledged_revision_count: 1, failed_revision_count: 0,
      oldest_pending_age_seconds: 1_800, pay_period_ids: [ period.id ])
    expect(old.reload.delivery_status).to eq("failed")
  end

  it "uses only the latest valid preview for missing-match snapshots without exposing its people" do
    import.update!(processed_payload: { rows: [ { source_user_id: "42", employee_id: nil, source_display_name: "Private person" },
      { source_user_id: "42", employee_id: nil }, { source_user_id: "43", employee_id: 123 } ] })
    expect(report[:latest_import_mapping_review]).to include(status: "recorded", missing_count: 1, pay_period_id: period.id)
    expect(report.to_json).not_to include("Private person")
    import.update!(processed_payload: { rows: [ {} ] })
    expect(report[:latest_import_mapping_review]).to include(status: "unavailable", missing_count: nil)
    import.update!(processed_payload: { rows: Array.new(5_001) { { source_user_id: "42", employee_id: nil } } })
    expect(report[:latest_import_mapping_review]).to include(status: "unavailable", missing_count: nil)
  end

  it "bounds repair links while counting the complete local queue" do
    7.times do
      item = create(:time_tracking_import, time_tracking_source: source, pay_period: create(:pay_period, company: company))
      AirePayrollAcknowledgement.record!(time_tracking_import: item, status: "imported", occurred_at: now)
    end
    expect(report.dig(:receipts, :batch, :pending_count)).to eq(7)
    expect(report.dig(:receipts, :batch, :pay_period_ids).length).to eq(5)
  end

  it "groups repeated imports before limiting repair links and orders distinct runs oldest first" do
    8.times do |index|
      repeated = create(:time_tracking_import, time_tracking_source: source, pay_period: period,
        created_at: now - 2.days + index.minutes, source_payload_hash: Digest::SHA256.hexdigest("health-import-#{index}"))
      AirePayrollAcknowledgement.record!(time_tracking_import: repeated, status: "imported", occurred_at: now)
    end
    others = 6.times.map do |index|
      other_period = create(:pay_period, company: company)
      other_import = create(:time_tracking_import, time_tracking_source: source, pay_period: other_period,
        created_at: now - 1.day + index.minutes)
      AirePayrollAcknowledgement.record!(time_tracking_import: other_import, status: "imported", occurred_at: now)
      other_period.id
    end
    expect(report.dig(:receipts, :batch)).to include(pending_count: 14, pay_period_ids: [ period.id, *others.first(4) ])
  end

  it "combines distinct classification and manual runs by oldest priority before limiting links" do
    employee = create(:employee, company: company)
    actor = create(:user, company: company)
    8.times do |index|
      reviewed_employee = create(:employee, company: company)
      item = create(:payroll_item, employee: reviewed_employee, pay_period: period)
      TimeTrackingClassificationReconciliation.create!(company: company, time_tracking_source: source,
        pay_period: period, payroll_item: item, employee: reviewed_employee, created_by: actor,
        source_user_uuid: SecureRandom.uuid, source_regular_hours: 1, source_overtime_hours: 1,
        payroll_regular_hours: 2, payroll_overtime_hours: 0, check_number: "1003",
        payment_effective_on: Date.current, gross_wage_difference: 0, note: "Owner reviewed exact check",
        created_at: now - 1.day + index.minutes)
    end
    others = 6.times.map do |index|
      other_period = create(:pay_period, company: company)
      other_item = create(:payroll_item, employee: employee, pay_period: other_period)
      8.times do |entry|
        TimeTrackingManualAllocation.create!(company: company, time_tracking_source: source,
          pay_period: other_period, payroll_item: other_item, employee: employee, created_by: actor,
          source_user_uuid: SecureRandom.uuid, source_time_entry_id: "#{index}-#{entry}",
          source_time_entry_version: 1, original_work_date: Date.current, regular_hours: 1,
          overtime_hours: 0, reconciliation_note: "Owner approved", status: "pending_commit",
          created_at: now - 2.days + index.minutes + entry.seconds)
      end
      other_period.id
    end
    expect(report[:reconciliation]).to include(pending_classification_count: 8,
      manual_pending_commit_count: 48, pay_period_ids: others.first(5))
  end

  it "keeps entry receipt ownership scoped to its native item and imported period" do
    employee = create(:employee, company: company)
    item = create(:payroll_item, employee: employee, pay_period: period)
    ack = AirePayrollEntryAcknowledgement.create!(time_tracking_import: import, payroll_item: item,
      source_event_key: "synthetic-health", event_id: SecureRandom.uuid, source_time_entry_id: "42", source_user_id: "7",
      status: "payment_issued", occurred_at: now, created_at: now - 60.minutes)
    expect(report.dig(:receipts, :entry)).to include(recorded_count: 1, pending_count: 1, oldest_pending_age_seconds: 3600)
    ack.mark_delivered!(at: now)
    expect(report.dig(:receipts, :entry)).to include(recorded_count: 1, pending_count: 0, last_success_at: now)
    ack.update_columns(payroll_item_id: create(:payroll_item).id)
    expect(report.dig(:receipts, :entry, :recorded_count)).to eq(0)
  end

  it "summarizes only pending local classification and active manual sync review, without money owed" do
    employee = create(:employee, company: company)
    item = create(:payroll_item, employee: employee, pay_period: period)
    actor = create(:user, company: company)
    uuid = SecureRandom.uuid
    TimeTrackingClassificationReconciliation.create!(company: company, time_tracking_source: source,
      pay_period: period, payroll_item: item, employee: employee, created_by: actor, source_user_uuid: uuid,
      source_regular_hours: 1, source_overtime_hours: 1, payroll_regular_hours: 2, payroll_overtime_hours: 0,
      check_number: "1003", payment_effective_on: Date.current, gross_wage_difference: 0,
      note: "Owner reviewed exact check")
    %w[pending_commit committed voided].each do |status|
      TimeTrackingManualAllocation.create!(company: company, time_tracking_source: source, pay_period: period,
        payroll_item: item, employee: employee, created_by: actor, source_user_uuid: uuid,
        source_time_entry_id: status, source_time_entry_version: 1, original_work_date: Date.current,
        regular_hours: 1, overtime_hours: 0, reconciliation_note: "Owner approved", status: status,
        last_sync_error: status == "pending_commit" ? nil : "Sensitive transport failure")
    end
    expect(report[:reconciliation]).to include(pending_classification_count: 1, manual_pending_commit_count: 1,
      manual_sync_failed_count: 1, pay_period_ids: [ period.id ])
    expect(report.to_json).not_to match(/Sensitive transport|owed|check_number/)
  end
end
