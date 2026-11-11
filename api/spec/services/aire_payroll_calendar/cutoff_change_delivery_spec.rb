# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendar::Delivery, "with an admin lock time" do
  include_context "aire cutoff change fixture"

  let(:client) { instance_double(TimeTracking::Client) }

  def lock_now!
    publish_delivered_calendar!
    AirePayrollCalendar::CutoffChange.new(pay_period: pay_period, action: "lock_now", reason: "Ready early", actor: org_admin).call.publication
  end

  def aire_state(publication, overrides = {})
    publication.payload.slice("start_date", "end_date", "pay_date", "cutoff_at", "overtime_policy", "lock_mode",
      "cutoff_enforcement_starts_on", "cutoff_source", "cutoff_override").merge(
      "external_pay_period_id" => publication.aire_payroll_calendar_period.external_pay_period_id,
      "schedule_version" => publication.schedule_version,
      "publication_id" => publication.publication_id,
      "status" => "scheduled",
      "cutoff_state" => "due",
      "next_scheduled_cutoff_at" => nil
    ).merge(overrides)
  end

  def deliver(publication, at:)
    described_class.new(publication_id: publication.id, now: at, client_factory: ->(*) { client }).call
  end

  it "delivers a lock-now revision after its instant and keeps retrying a lost response after the grace window" do
    publication = lock_now!
    allow(client).to receive(:publish_payroll_calendar_period).and_raise(TimeTracking::Client::Error, "AIRE unavailable")

    expect(deliver(publication, at: 1.minute.from_now)[:status]).to eq("failed")
    expect(publication.reload.next_delivery_attempt_at).to be_present

    # AIRE may have applied it; it replays the publication_id before any time check.
    publication.update_columns(next_delivery_attempt_at: 2.hours.from_now)
    deliver(publication, at: 2.hours.from_now)
    expect(publication.reload.next_delivery_attempt_at).to be_present

    allow(client).to receive(:publish_payroll_calendar_period).and_return("payroll_calendar_period" => aire_state(publication, "cutoff_state" => "finalized"))
    publication.update_columns(next_delivery_attempt_at: 3.hours.from_now)
    expect(deliver(publication, at: 3.hours.from_now)[:status]).to eq("delivered")
    expect(publication.reload.source_state["cutoff_state"]).to eq("finalized")
  end

  it "stops retrying once AIRE refuses a publication whose time has passed" do
    publication = lock_now!
    allow(client).to receive(:publish_payroll_calendar_period)
      .and_raise(TimeTracking::Client::Error.new("cutoff_at must be in the future when published", response_status: 422))

    deliver(publication, at: 31.minutes.from_now)
    expect(publication.reload).to have_attributes(delivery_status: "failed", last_response_status: 422, next_delivery_attempt_at: nil)
    expect(publication).to be_rejected
    expect(publication.rejection_message).to eq("cutoff_at must be in the future when published")
  end

  it "stops retrying a version once AIRE confirmed a newer one" do
    stale = lock_now!
    reject_delivery!(stale, "Lock now came after manual payroll claims", status: 409)
    stale.update_columns(next_delivery_attempt_at: Time.current)
    newer = AirePayrollCalendar::CutoffChange.new(pay_period: pay_period, action: "lock_now", reason: "Again", actor: org_admin).call.publication
    confirm_delivery!(newer)

    expect(client).not_to receive(:publish_payroll_calendar_period)
    expect(deliver(stale, at: Time.current)[:status]).to eq("superseded")
    expect(stale.reload).to have_attributes(next_delivery_attempt_at: nil, last_error: "Superseded by schedule version 3, which AIRE confirmed")
  end

  it "fails delivery when AIRE stored the period without the override" do
    publication = lock_now!
    allow(client).to receive(:publish_payroll_calendar_period).and_return(
      "payroll_calendar_period" => aire_state(publication, "cutoff_source" => "policy").except("cutoff_override")
    )

    expect(deliver(publication, at: 1.minute.from_now)).to include(status: "failed")
    expect(publication.reload.last_error).to include("does not match this publication")
  end
end
