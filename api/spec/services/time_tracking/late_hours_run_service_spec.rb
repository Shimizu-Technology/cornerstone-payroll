# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::LateHoursRunService do
  before { ensure_verified_test_tax_years(2026) }
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:workweek) do
    CompanyWorkweek.create!(company: company, starts_on_weekday: 0, starts_at_minutes: 0,
      timezone: "Pacific/Guam", source: "operator_confirmed", confirmation_status: "confirmed",
      confirmed_by: actor, confirmed_at: Time.current, effective_on: "2020-01-01", notes: "Late hours test workweek")
  end
  let(:period) { create(:pay_period, company: company, company_workweek: workweek, start_date: "2026-10-01", end_date: "2026-10-15", pay_date: "2026-10-20") }
  let!(:calendar) { create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: period) }
  let(:employee) { create(:employee, company: company, pay_rate: 25, employment_type: "hourly") }
  let!(:rate) { create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 25, is_primary: true) }
  let(:uuid) { SecureRandom.uuid }
  let!(:mapping) { TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source, employee: employee, source_user_id: "42", source_user_uuid: uuid) }
  let(:client) { instance_double(TimeTracking::Client) }
  let(:case_id) { SecureRandom.uuid }
  let(:cases) { [ { "id" => case_id, "version" => 2 } ] }
  let(:command_id) { SecureRandom.uuid }
  let(:line) do
    build_aire_batch_payload.fetch("employees").first.fetch("adjustments").first.merge(
      "source_kind" => "carryover", "source_time_entry_version" => 3, "total_hours" => 4, "regular_hours" => 4)
  end
  let(:review) do
    { "period_version" => 5, "cases" => [ { "id" => case_id, "version" => 2,
      "employee" => { "payroll_integration_id" => uuid, "source_user_id" => "42", "name" => "Pilot One" },
      "reason" => "approved_after_cutoff", "adjustments" => [ line ], "total_hours" => 4, "regular_hours" => 4, "overtime_hours" => 0 } ] }
  end
  let(:service) { described_class.new(pay_period: period, source: source, actor: actor) }

  before do
    allow(source).to receive(:historical_reconciliation_complete?).and_return(true)
    allow_any_instance_of(TimeTrackingSource).to receive(:historical_reconciliation_complete?).and_return(true)
    allow(TimeTracking::Client).to receive(:for_payroll_actor).and_return(client)
    allow(client).to receive(:payroll_cockpit_late_hours).and_return(review)
    allow(client).to receive(:create_payroll_late_hours) do |**request|
      claim_response(request.fetch(:target_external_pay_period_id))
    end
    allow(client).to receive(:recover_payroll_late_hours) do |**request|
      claim_response(request.fetch(:target_external_pay_period_id)).merge("status" => "claimed")
    end
  end

  def claim_response(target)
    payload = build_aire_batch_payload(batch_id: "AIRE-LATE-TEST")
    payload.merge!("purpose" => "supplemental", "target_external_pay_period_id" => target, "exclusions" => [])
    payload["employees"].first.merge!("source_user_uuid" => uuid, "adjustments" => [ line ], "total_hours" => 4, "regular_hours" => 4)
    payload["summary"].merge!("total_hours" => 4, "regular_hours" => 4, "exclusion_count" => 0, "current_count" => 0, "carryover_count" => 1)
    payload["issues"]["pending_approval_count"] = 0
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    { "payroll_batch" => payload }
  end

  def create_run
    service.create!(command_id: command_id, cases: cases, pay_date: "2026-10-24", expected_version: 5)
  end

  it "creates exactly four captured-rate hours in an adjustment and replays without another payroll or source claim" do
    original = period.reload.attributes
    run = create_run
    adjustment = run.adjustment_pay_period
    expect(adjustment).to have_attributes(run_purpose: "adjustment", includes_base_salary: false, includes_recurring_items: false)
    expect(adjustment.payroll_items.count).to eq(1)
    item = adjustment.payroll_items.first
    expect(item.hours_worked).to eq(4)
    expect(item.wage_rate_hours.first.fetch("rate")).to eq(25)
    expect(item.time_tracking_entry_allocations.pluck(:total_hours)).to eq([ 4 ])
    expect(period.reload.attributes).to eq(original)
    expect(AirePayrollAcknowledgement.where(time_tracking_import: adjustment.time_tracking_imports)).to be_empty
    expect(AirePayrollEntryAcknowledgement.where(time_tracking_import: adjustment.time_tracking_imports).pluck(:status)).to eq([ "imported" ])
    expect(create_run.id).to eq(run.id)
    expect(client).to have_received(:create_payroll_late_hours).once
    expect { item.update!(hours_worked: 8) }.to raise_error(ActiveRecord::RecordInvalid, /captured earning/)
  end

  it "resumes an ambiguous network failure using the same command, destination and captured rate" do
    allow(client).to receive(:create_payroll_late_hours).and_raise(TimeTracking::Client::Error, "Connection timed out")
    expect { create_run }.to raise_error(TimeTracking::Client::Error, /timed out/)
    rate.update!(rate: 40)
    run = create_run
    expect(run.adjustment_pay_period.payroll_items.first.wage_rate_hours.first.fetch("rate")).to eq(25)
    expect(TimeTrackingLateHoursRun.count).to eq(1)
    expect(client).to have_received(:recover_payroll_late_hours).with(hash_including(source_command_id: command_id,
      target_external_pay_period_id: run.adjustment_pay_period_id.to_s))
  end

  it "refuses hours no longer eligible, including reserved or already routed source cases" do
    review["cases"] = []
    expect(client).not_to receive(:create_payroll_late_hours)
    expect { create_run }.to raise_error(described_class::Error, /no longer available/)
    expect(TimeTrackingLateHoursRun.count).to eq(0)
  end

  it "refuses a changed case version before creating a destination" do
    cases.first["version"] = 1
    expect { create_run }.to raise_error(described_class::Error, /changed/)
  end

  it "requires Client management even when the accountant can access this company" do
    actor.update!(role: "accountant")
    expect(client).not_to receive(:payroll_cockpit_late_hours)
    expect { create_run }.to raise_error(described_class::Error, /Client management/)
  end

  it "refuses reuse of an idempotency key with different selections" do
    create_run
    expect { service.create!(command_id: command_id, cases: cases, pay_date: "2026-10-25", expected_version: 5) }
      .to raise_error(described_class::Error, /different/)
  end
  it "refuses a response with extra source hours and holds calculation while recovery is incomplete" do
    allow(client).to receive(:create_payroll_late_hours).and_raise(TimeTracking::Client::Error, "Source offline")
    expect { create_run }.to raise_error(TimeTracking::Client::Error)
    run = TimeTrackingLateHoursRun.last
    expect { run.adjustment_pay_period.update!(status: "calculated") }.to raise_error(ActiveRecord::RecordInvalid, /Finish importing/)
    changed = build_aire_batch_payload(batch_id: "AIRE-WRONG-HOURS")
    run.update!(batch_payload: changed)
    expect { service.retry!(run.id) }.to raise_error(described_class::Error, /different hours/)
    expect(run.adjustment_pay_period.payroll_items).to be_empty
  end

  it "retains exact split lines on the day after the origin period" do
    line["original_work_date"] = "2026-10-16"
    line["original_week_start"] = "2026-10-11"
    run = create_run
    expect(run.adjustment_pay_period.payroll_items.first.time_tracking_entry_allocations.sole.original_work_date).to eq(Date.new(2026, 10, 16))
  end
  it "blocks unrelated employee pay in the source-only adjustment" do
    run = create_run
    other = create(:employee, company: company)
    expect { create(:payroll_item, company: company, pay_period: run.adjustment_pay_period, employee: other) }
      .to raise_error(ActiveRecord::RecordInvalid, /only its selected source hours/)
  end

  it "calculates and commits through normal payroll with exact committed receipts and no aggregate acknowledgement" do
    run = create_run
    adjustment = run.adjustment_pay_period
    item = adjustment.payroll_items.sole
    item.calculate!
    item.save!
    expect(item.gross_pay).to eq(100)
    adjustment.update!(status: "calculated")
    lifecycle = PayPeriodLifecycleService.new(pay_period: adjustment, actor: actor)
    lifecycle.approve!
    lifecycle.commit!
    expect(adjustment.reload.status).to eq("committed")
    expect(AirePayrollAcknowledgement.where(time_tracking_import: adjustment.time_tracking_imports)).to be_empty
    expect(AirePayrollEntryAcknowledgement.where(time_tracking_import: adjustment.time_tracking_imports).pluck(:status)).to include("committed")
    expect(item.reload.check_events.deliveries).to be_empty
  end

  it "keeps the saved destination visible when the source goes offline after an ambiguous create" do
    allow(client).to receive(:create_payroll_late_hours).and_raise(TimeTracking::Client::Error, "Source offline")
    expect { create_run }.to raise_error(TimeTracking::Client::Error)
    saved = TimeTrackingLateHoursRun.sole
    allow(client).to receive(:payroll_cockpit_late_hours).and_raise(TimeTracking::Client::Error, "Source offline")
    expect(service.review).to include("source_error" => "Source offline", "cases" => [])
    expect(service.review.fetch("runs").sole).to include(id: saved.id, pay_period_id: saved.adjustment_pay_period_id, applied: false)
  end
  it "holds an ambiguous retry when the employee's pay basis changes after selection" do
    allow(client).to receive(:create_payroll_late_hours).and_raise(TimeTracking::Client::Error, "Source offline")
    expect { create_run }.to raise_error(TimeTracking::Client::Error)
    saved = TimeTrackingLateHoursRun.sole
    employee.update!(employment_type: "salary", pay_rate: 50000)
    payload = build_aire_batch_payload
    allow(client).to receive(:create_payroll_late_hours).and_return("payroll_batch" => payload)
    # Source selection verification is independent; this isolates the captured payroll basis guard.
    allow(service).to receive(:verify_selection!)
    expect { service.retry!(saved.id) }.to raise_error(described_class::Error, /pay basis changed/)
    expect(saved.adjustment_pay_period.payroll_items).to be_empty
  end

  # Ported from the independent paired review's payroll_probes_spec.rb.
  it "retires an authoritative stale rejection and permits the refreshed selection" do
    allow(client).to receive(:create_payroll_late_hours).and_raise(TimeTracking::Client::Error.new("Selected source changed", response_status: 409))
    allow(client).to receive(:recover_payroll_late_hours).and_return("status" => "no_claim")
    expect { create_run }.to raise_error(TimeTracking::Client::Error, /changed/)
    saved = TimeTrackingLateHoursRun.sole
    expect(saved.reload.state).to eq("rejected")
    expect(saved.resolved_by_id).to eq(actor.id)
    review["cases"].sole["version"] = 3
    expect(service.review.fetch("cases").sole["blocked_reason"]).to be_nil
    expect { service.retry!(saved.id) }.to raise_error(described_class::Error, /closed/)
    expect(saved.request_payload.fetch("cases").sole["version"]).to eq(2)
    allow(client).to receive(:create_payroll_late_hours) { |**request| claim_response(request.fetch(:target_external_pay_period_id)) }
    fresh = service.create!(command_id: SecureRandom.uuid, cases: [ { "id" => case_id, "version" => 3 } ], pay_date: "2026-10-24", expected_version: 5)
    expect(fresh.applied_at).to be_present
    expect(fresh.adjustment_pay_period.payroll_items.sole.hours_worked).to eq(4)
    expect(fresh.adjustment_pay_period_id).not_to eq(saved.adjustment_pay_period_id)
  end

  it "persists an accepted unusable claim and requires reviewed cancellation before releasing it" do
    template = client.create_payroll_late_hours(external_pay_period_id: calendar.external_pay_period_id, target_external_pay_period_id: "1")
    allow(client).to receive(:create_payroll_late_hours) do |**request|
      payload = template.fetch("payroll_batch").deep_dup
      payload["target_external_pay_period_id"] = request.fetch(:target_external_pay_period_id)
      payload["employees"].sole["adjustments"].sole.merge!("regular_hours" => 3, "overtime_hours" => 1)
      payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
      { "payroll_batch" => payload }
    end
    expect { create_run }.to raise_error(described_class::Error, /different hours/)
    saved = TimeTrackingLateHoursRun.sole
    expect(saved.batch_payload).not_to be_empty
    expect(saved.state).to eq("reconciliation_required")
    expect(saved.adjustment_pay_period.payroll_items).to be_empty
    expect { service.cancel!(saved.id, reason: "") }.to raise_error(described_class::Error, /reason/)
    allow(client).to receive(:cancel_payroll_late_hours).and_return("status" => "canceled")
    service.cancel!(saved.id, reason: "Reviewed changed overtime; cancel this unpaid claim and select the current hours")
    expect(saved.reload.state).to eq("cancelled")
    expect(saved.batch_payload).not_to be_empty
    expect(service.review.fetch("cases").sole["blocked_reason"]).to be_nil
    expect(AuditLog.where(record_type: "TimeTrackingLateHoursRun", record_id: saved.id)).not_to be_empty
  end

  it "blocks only conflicting cases while an ambiguous operation waits" do
    allow(client).to receive(:create_payroll_late_hours).and_raise(TimeTracking::Client::Error, "Response lost")
    expect { create_run }.to raise_error(TimeTracking::Client::Error)
    other = review["cases"].sole.deep_dup.merge("id" => SecureRandom.uuid)
    other["adjustments"].sole["source_time_entry_id"] = "another-entry"
    review["cases"] << other
    available = service.review.fetch("cases").index_by { |row| row.fetch("id") }
    expect(available.fetch(case_id)["blocked_reason"]).to match(/saved adjustment/)
    expect(available.fetch(other.fetch("id"))["blocked_reason"]).to be_nil
  end

  it "recovers a lost response as a second authorized accountant after the creator loses access" do
    template = client.create_payroll_late_hours(external_pay_period_id: calendar.external_pay_period_id, target_external_pay_period_id: "1")
    allow(client).to receive(:create_payroll_late_hours).and_raise(TimeTracking::Client::Error, "Response lost after remote commit")
    expect { create_run }.to raise_error(TimeTracking::Client::Error)
    saved = TimeTrackingLateHoursRun.sole
    actor.update!(role: "accountant")
    second = create(:user, company: company, organization: company.organization, role: "accountant")
    create(:company_assignment, user: second, company: company, client_management: true, granted_by: create(:user, company: company, role: "admin"))
    payload = template.fetch("payroll_batch")
    payload["target_external_pay_period_id"] = saved.adjustment_pay_period_id.to_s
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    allow(client).to receive(:recover_payroll_late_hours).and_return("status" => "claimed", "payroll_batch" => payload)
    other_service = described_class.new(pay_period: period, source: source, actor: second)
    expect(TimeTracking::Client).to receive(:for_payroll_actor).with(source, actor: second).and_return(client)
    expect(other_service.retry!(saved.id).applied_at).to be_present
    expect(saved.reload.resolved_by_id).to eq(second.id)
    expect(TimeTrackingLateHoursRun.count).to eq(1)
    expect(saved.adjustment_pay_period.payroll_items.sole.hours_worked).to eq(4)
    expect { service.retry!(saved.id) }.to raise_error(described_class::Error, /Client management/)
  end

  it "keeps an authoritative rejection ambiguous until the remote fence is confirmed" do
    allow(client).to receive(:create_payroll_late_hours).and_raise(TimeTracking::Client::Error.new("Source changed", response_status: 409))
    allow(client).to receive(:recover_payroll_late_hours).and_raise(TimeTracking::Client::Error, "Recovery unavailable")
    expect { create_run }.to raise_error(TimeTracking::Client::Error, /changed/)
    saved = TimeTrackingLateHoursRun.sole
    expect(saved.state).to eq("ambiguous")
    expect(saved).not_to be_closed
    expect(service.review.fetch("cases").sole["blocked_reason"]).to match(/saved adjustment/)
  end

  it "never releases a claim when remote cancellation refuses or times out" do
    allow(client).to receive(:create_payroll_late_hours).and_raise(TimeTracking::Client::Error, "Lost response")
    expect { create_run }.to raise_error(TimeTracking::Client::Error)
    saved = TimeTrackingLateHoursRun.sole
    allow(client).to receive(:cancel_payroll_late_hours).and_raise(TimeTracking::Client::Error.new("Claim has receipt evidence", response_status: 409))
    expect { service.cancel!(saved.id, reason: "Reviewed unpaid claim for cancellation") }.to raise_error(TimeTracking::Client::Error)
    expect(saved.reload).not_to be_closed
    expect(saved.batch_payload).not_to be_empty
  end

  it "refuses cancellation once exact hours are locally imported" do
    saved = create_run
    expect(client).not_to receive(:cancel_payroll_late_hours)
    expect { service.cancel!(saved.id, reason: "Cancel after hours have been imported") }.to raise_error(described_class::Error, /Only an unapplied/)
    expect(saved.reload.state).to eq("applied")
    expect(saved.adjustment_pay_period.payroll_items.sole.hours_worked).to eq(4)
  end

  it "rechecks the accountant's grant after the remote period lookup before recovery" do
    allow(client).to receive(:create_payroll_late_hours).and_raise(TimeTracking::Client::Error, "Lost response")
    expect { create_run }.to raise_error(TimeTracking::Client::Error)
    saved = TimeTrackingLateHoursRun.sole
    allow(client).to receive(:payroll_cockpit_late_hours) do
      actor.update!(role: "accountant")
      review
    end
    expect(client).not_to receive(:recover_payroll_late_hours)
    expect { service.retry!(saved.id) }.to raise_error(described_class::Error, /Client management/)
    expect(saved.reload).not_to be_closed
  end
end
