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

  it "delivers a lock-now revision after its instant and keeps retrying only within the grace window" do
    publication = lock_now!
    allow(client).to receive(:publish_payroll_calendar_period).and_raise(TimeTracking::Client::Error, "AIRE unavailable")

    expect(deliver(publication, at: 1.minute.from_now)[:status]).to eq("failed")
    expect(publication.reload.next_delivery_attempt_at).to be_present

    publication.update_columns(next_delivery_attempt_at: 31.minutes.from_now)
    deliver(publication, at: 31.minutes.from_now)
    expect(publication.reload.next_delivery_attempt_at).to be_nil

    allow(client).to receive(:publish_payroll_calendar_period).and_return("payroll_calendar_period" => aire_state(publication))
    publication.update_columns(next_delivery_attempt_at: 2.minutes.from_now)
    expect(deliver(publication, at: 2.minutes.from_now)[:status]).to eq("delivered")
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
