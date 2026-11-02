# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendar::LockRollout do
  let(:source) { create(:time_tracking_source, source_type: "aire_services") }
  let(:period) { create(:pay_period, company: source.company, start_date: "2026-10-01", end_date: "2026-10-15", pay_date: "2026-10-31") }
  let(:calendar) { create(:aire_payroll_calendar_period, company: source.company, time_tracking_source: source, pay_period: period) }
  let(:service) { described_class.new(source: source, starts_on: "2026-10-16", actor: "Release operator", reason: "Approved rollout") }

  it "accepts an empty inventory and audits the operator, reason, source and immutable boundary on every invocation" do
    2.times { expect(service.configure!).to include(status: "configured", source_id: source.id) }
    logs = AuditLog.where(action: "time_tracking_source#lock_rollout_gate_passed", record_id: source.id)
    expect(logs.count).to eq(2)
    expect(logs.last).to have_attributes(actor_name: "Release operator", company_id: source.company_id)
    expect(logs.last.metadata).to include("reason" => "Approved rollout", "cutoff_enforcement_starts_on" => "2026-10-16")
  end

  it "appends an initial later boundary only before any explicit gate or calendar, retaining the legacy column" do
    later = described_class.new(source: source, starts_on: "2026-11-01", actor: "Release operator", reason: "Approved later Stage 2 initial boundary")
    expect(later.configure!).to include(cutoff_enforcement_starts_on: "2026-11-01")
    expect(source.reload.cutoff_enforcement_starts_on).to eq(Date.new(2026, 11, 1))
    expect(source[:cutoff_enforcement_starts_on]).to eq(Date.new(2026, 10, 16))
    expect { service.configure! }.to raise_error(described_class::Error, /immutable|only move later/)
    expect(later.configure!).to include(status: "configured")
    expect(TimeTrackingLockRolloutSelection.count).to eq(1)
    audit = AuditLog.find_by!(action: "time_tracking_source#initial_lock_rollout_selected", record_id: source.id)
    expect(audit.metadata).to include("old_starts_on" => "2026-10-16", "new_starts_on" => "2026-11-01")
    expect(audit.actor_name).to eq("Release operator")
    selection = source.lock_rollout_selection
    expect { selection.update!(starts_on: "2026-11-16") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect do
      TimeTrackingLockRolloutSelection.transaction(requires_new: true) { selection.delete }
    end.to raise_error(ActiveRecord::StatementInvalid, /immutable/)
  end

  it "refuses later selection after a prior explicit gate" do
    service.configure!
    expect do
      described_class.new(source: source, starts_on: "2026-11-01", actor: "Release operator", reason: "Approved later Stage 2 initial boundary").configure!
    end.to raise_error(described_class::Error, /immutable/)
    expect(TimeTrackingLockRolloutSelection.count).to eq(0)
  end

  it "rejects an orphan preactivation calendar even during an idempotent recheck" do
    service.configure!
    calendar
    expect { service.configure! }.to raise_error(described_class::Error, /no explicit manual/)
    expect(AuditLog.where(action: "time_tracking_source#lock_rollout_gate_passed").count).to eq(1)
  end

  [ {}, { "lock_mode" => "manual" }, { "lock_mode" => "scheduled", "cutoff_enforcement_starts_on" => "2026-10-16" },
    { "lock_mode" => "manual", "cutoff_enforcement_starts_on" => "2026-10-01" } ].each do |policy|
    it "rejects preactivation publication policy #{policy.inspect} without rewriting it" do
      service.configure!
      payload = build(:aire_payroll_calendar_publication).payload.merge(policy)
      publication = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, payload: payload)
      # Configure-once does not grandfather a legacy row arriving after an earlier gate.
      original = publication.attributes
      expect { service.configure! }.to raise_error(described_class::Error, /lacks explicit manual/)
      expect(publication.reload.attributes).to eq(original)
    end
  end

  it "accepts explicit manual evidence but still rejects an older legacy revision" do
    legacy = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar)
    create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, schedule_version: 2,
      payload: legacy.payload.merge("lock_mode" => "manual", "cutoff_enforcement_starts_on" => "2026-10-16"))
    expect { service.configure! }.to raise_error(described_class::Error, /lacks explicit manual/)
  end

  it "accepts explicit manual publications and leaves immutable evidence intact" do
    payload = build(:aire_payroll_calendar_publication).payload.merge("lock_mode" => "manual", "cutoff_enforcement_starts_on" => "2026-10-16")
    publication = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, payload: payload)
    expect(service.configure!).to include(status: "configured")
    expect(publication.reload.payload).to eq(payload)
  end

  it "retains on-or-after-activation legacy scheduled evidence" do
    period.update!(start_date: "2026-10-16", end_date: "2026-10-31", pay_date: "2026-11-15")
    payload = build(:aire_payroll_calendar_publication).payload.merge("start_date" => "2026-10-16", "end_date" => "2026-10-31")
    create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, payload: payload)
    expect(service.configure!).to include(status: "configured")
  end

  it "rejects missing attribution, invalid dates and a boundary mismatch" do
    [ [ "2026-10-16", "", "Reason" ], [ "2026-10-16", "Actor", "" ], [ "2026-10-03", "Actor", "Reason" ],
      [ "2026-11-01", "Actor", "Reason" ], [ "nonsense", "Actor", "Reason" ] ].each do |starts_on, actor, reason|
      expect { described_class.new(source: source, starts_on: starts_on, actor: actor, reason: reason).configure! }.to raise_error(described_class::Error)
    end
  end
end
